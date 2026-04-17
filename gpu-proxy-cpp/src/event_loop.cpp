#include "event_loop.hpp"
#include <sys/poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <cerrno>

namespace gpu_proxy {

EventLoop::EventLoop() {
}

EventLoop::~EventLoop() {
    stop();
}

void EventLoop::add_connection(std::unique_ptr<Connection> conn) {
    int fd = conn->fd();
    connections_[fd] = std::move(conn);
    fprintf(stderr, "[EventLoop] Added connection %d, total: %zu\n",
            fd, connections_.size());
}

void EventLoop::remove_connection(int fd) {
    auto it = connections_.find(fd);
    if (it != connections_.end()) {
        fprintf(stderr, "[EventLoop] Removing connection %d (%s)\n",
                fd, it->second->name().c_str());
        connections_.erase(it);
    }
}

Connection* EventLoop::get_connection(int fd) {
    auto it = connections_.find(fd);
    return it != connections_.end() ? it->second.get() : nullptr;
}

uint64_t EventLoop::now_ms() const {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000 +
           static_cast<uint64_t>(ts.tv_nsec) / 1000000;
}

void EventLoop::set_timeout(uint64_t interval_ms, TimeoutCallback cb, bool recurring) {
    Timeout timeout;
    timeout.next_fire_ms = now_ms() + interval_ms;
    timeout.interval_ms = interval_ms;
    timeout.callback = std::move(cb);
    timeout.recurring = recurring;
    timeouts_.push_back(std::move(timeout));
}

void EventLoop::poll_and_process(int timeout_ms) {
    if (connections_.empty()) {
        // No connections, just sleep
        usleep(timeout_ms * 1000);
        return;
    }

    // Build pollfd array
    std::vector<struct pollfd> pfds;
    pfds.reserve(connections_.size());

    for (auto& [fd, conn] : connections_) {
        struct pollfd pfd {};
        pfd.fd = fd;

        // Always check for errors and hangup
        pfd.events = POLLERR | POLLHUP;

        // TLS handshake takes priority - use want_* flags to determine events
        if (conn->tls_handshake_pending()) {
            if (conn->tls_waiting_for_write()) {
                pfd.events |= POLLOUT;
            } else if (conn->tls_waiting_for_read()) {
                pfd.events |= POLLIN;
            } else {
                // Initial TLS handshake - try both until we know what we need
                pfd.events |= POLLIN | POLLOUT;
            }
        }
        // TCP connection in progress
        else if (conn->state() == ConnectionState::CONNECTING) {
            pfd.events |= POLLOUT;
        }
        // Normal connected state - check for read
        else if (conn->is_connected()) {
            pfd.events |= POLLIN;
        }

        pfds.push_back(pfd);
    }

    // Poll
    int ret = poll(pfds.data(), pfds.size(), timeout_ms);
    if (ret < 0) {
        if (errno == EINTR) {
            return;  // Interrupted by signal
        }
        fprintf(stderr, "[EventLoop] Poll error: %s\n", strerror(errno));
        return;
    }

    if (ret == 0) {
        return;  // Timeout
    }

    // Process events
    for (size_t i = 0; i < pfds.size(); ++i) {
        int fd = pfds[i].fd;
        auto* conn = get_connection(fd);
        if (!conn) continue;

        // Check for errors
        if (pfds[i].revents & (POLLERR | POLLHUP)) {
            fprintf(stderr, "[EventLoop] Error/hangup on %s (fd=%d, revents=0x%x)\n",
                    conn->name().c_str(), fd, pfds[i].revents);
            conn->mark_for_closing();
            continue;
        }

        // Check for write (connect complete or TLS handshake progress)
        if (pfds[i].revents & POLLOUT) {
            handle_write_event(conn);
        }

        // Check for read
        if (pfds[i].revents & POLLIN) {
            fprintf(stderr, "[EventLoop] POLLIN on %s (fd=%d)\n", conn->name().c_str(), fd);
            handle_read_event(conn);
        }
    }

    // Clean up closed connections
    cleanup_closed();
}

void EventLoop::handle_read_event(Connection* conn) {
    // Continue TLS handshake if pending - always attempt on POLLIN
    // The WANT_READ/WANT_WRITE flags are transient; retry the handshake
    // regardless of cached flag state since we got a POLLIN event.
    if (conn->tls_handshake_pending()) {
        if (conn->continue_tls_handshake()) {
            fprintf(stderr, "[EventLoop] %s: TLS handshake complete (after read)\n",
                    conn->name().c_str());
            // After handshake completes, try to read data immediately
            // (pool might have sent data along with handshake completion)
            if (conn->read_data() < 0) {
                conn->mark_for_closing();
            }
        }
        return;  // Don't try to read more if handshake still in progress
    }

    // Normal data reading
    if (conn->read_data() < 0) {
        // Read error or connection closed
        conn->mark_for_closing();
    }
}

void EventLoop::handle_write_event(Connection* conn) {
    if (conn->state() == ConnectionState::CONNECTING) {
        // Non-blocking connect completed, check result
        int error = 0;
        socklen_t len = sizeof(error);
        if (getsockopt(conn->fd(), SOL_SOCKET, SO_ERROR, &error, &len) == 0) {
            if (error == 0) {
                // For POOL connections, start TLS handshake - don't change state yet
                // For WORKER connections, no TLS, so set CONNECTED now
                if (conn->type() == ConnectionType::WORKER) {
                    conn->set_state(ConnectionState::CONNECTED);
                } else {
                    // POOL connection - TLS will start, stay in CONNECTING
                    // Only print this once
                    static std::unordered_map<int, bool> printed;
                    if (!printed[conn->fd()]) {
                        fprintf(stderr, "[EventLoop] %s: TCP connect complete, TLS handshake pending\n",
                                conn->name().c_str());
                        printed[conn->fd()] = true;
                    }
                }
            } else {
                fprintf(stderr, "[EventLoop] %s: Connect failed: %s\n",
                        conn->name().c_str(), strerror(error));
                conn->mark_for_closing();
            }
        }
    }

    // Continue TLS handshake if pending - always attempt on POLLOUT
    // The WANT_READ/WANT_WRITE flags are transient; retry the handshake
    // regardless of cached flag state since we got a POLLOUT event.
    if (conn->tls_handshake_pending()) {
        if (conn->continue_tls_handshake()) {
            fprintf(stderr, "[EventLoop] %s: TLS handshake complete\n",
                    conn->name().c_str());
            // After handshake completes, try to read data immediately
            if (conn->read_data() < 0) {
                conn->mark_for_closing();
            }
        }
    }
}

void EventLoop::cleanup_closed() {
    auto it = connections_.begin();
    while (it != connections_.end()) {
        if (it->second->should_close()) {
            fprintf(stderr, "[EventLoop] Closing connection %d (%s)\n",
                    it->first, it->second->name().c_str());
            it = connections_.erase(it);
        } else {
            ++it;
        }
    }
}

void EventLoop::check_timeouts() {
    uint64_t now = now_ms();

    // Use erase-remove pattern to remove one-shot timeouts after they fire
    auto it = timeouts_.begin();
    while (it != timeouts_.end()) {
        if (now >= it->next_fire_ms) {
            it->callback();
            if (it->recurring) {
                // Reschedule recurring timeouts
                it->next_fire_ms = now + it->interval_ms;
                ++it;
            } else {
                // Remove one-shot timeouts after firing
                it = timeouts_.erase(it);
            }
        } else {
            ++it;
        }
    }
}

void EventLoop::run() {
    running_ = true;
    fprintf(stderr, "[EventLoop] Starting event loop\n");

    while (running_) {
        // Calculate timeout for next event
        int timeout_ms = IDLE_POLL_MS;

        if (!timeouts_.empty()) {
            uint64_t now = now_ms();
            uint64_t next_timeout = timeouts_[0].next_fire_ms;

            for (const auto& t : timeouts_) {
                if (t.next_fire_ms < next_timeout) {
                    next_timeout = t.next_fire_ms;
                }
            }

            if (next_timeout > now) {
                uint64_t wait_ms = next_timeout - now;
                if (wait_ms < static_cast<uint64_t>(timeout_ms)) {
                    timeout_ms = static_cast<int>(wait_ms);
                }
            } else {
                timeout_ms = 0;  // Timeout has passed
            }
        }

        // Poll and process events
        poll_and_process(timeout_ms);

        // Check and execute timeouts
        check_timeouts();

        // Exit if no connections and not auto-starting new ones
        if (connections_.empty() && timeouts_.empty()) {
            fprintf(stderr, "[EventLoop] No connections or timeouts, exiting\n");
            break;
        }
    }

    fprintf(stderr, "[EventLoop] Event loop stopped\n");
}

} // namespace gpu_proxy
