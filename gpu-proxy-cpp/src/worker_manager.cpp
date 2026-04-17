#include "worker_manager.hpp"
#include "event_loop.hpp"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <sstream>
#include <iomanip>

namespace gpu_proxy {

WorkerManager::WorkerManager(EventLoop& loop, uint16_t port, const std::vector<WorkerConfig>& workers)
    : loop_(loop), listen_port_(port), worker_configs_(workers) {
    require_whitelist_ = !workers.empty();
}

WorkerManager::~WorkerManager() {
    if (listen_fd_ >= 0) {
        close(listen_fd_);
    }
}

void WorkerManager::start() {
    // Create listening socket
    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
        fprintf(stderr, "[WorkerManager] Failed to create socket: %s\n",
                strerror(errno));
        return;
    }

    // Set reuse address
    int opt = 1;
    setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind to port
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(listen_port_);

    if (bind(listen_fd_, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[WorkerManager] Failed to bind to port %d: %s\n",
                listen_port_, strerror(errno));
        close(listen_fd_);
        listen_fd_ = -1;
        return;
    }

    // Listen
    if (listen(listen_fd_, 5) < 0) {
        fprintf(stderr, "[WorkerManager] Failed to listen: %s\n", strerror(errno));
        close(listen_fd_);
        listen_fd_ = -1;
        return;
    }

    // Set non-blocking
    int flags = fcntl(listen_fd_, F_GETFL, 0);
    fcntl(listen_fd_, F_SETFL, flags | O_NONBLOCK);

    fprintf(stderr, "[WorkerManager] Listening on port %d\n", listen_port_);

    // Add a RECURRING callback to check for new connections
    // The recurring=true flag ensures accept_worker() is called every 100ms
    loop_.set_timeout(100, [this]() {
        accept_worker();
    }, true);  // true = recurring
}

void WorkerManager::accept_worker() {
    if (listen_fd_ < 0) return;

    struct sockaddr_in client_addr {};
    socklen_t addr_len = sizeof(client_addr);

    int client_fd = accept(listen_fd_, (struct sockaddr*)&client_addr, &addr_len);
    if (client_fd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            fprintf(stderr, "[WorkerManager] Accept error: %s\n", strerror(errno));
        }
        return;
    }

    // Get client address
    char client_ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, sizeof(client_ip));

    std::string worker_name = "worker:" + std::string(client_ip) + ":" + std::to_string(ntohs(client_addr.sin_port));
    fprintf(stderr, "[WorkerManager] Accepted connection from %s (fd=%d)\n",
            worker_name.c_str(), client_fd);

    // Create connection
    auto conn = std::make_unique<Connection>(client_fd, ConnectionType::WORKER, worker_name);

    // Set up callbacks
    conn->set_state_callback([this, conn_ptr = conn.get()](ConnectionState state) {
        on_worker_state(conn_ptr, state);
    });

    conn->set_message_callback([this, conn_ptr = conn.get()](const std::string& line) {
        on_worker_message(conn_ptr, line);
    });

    // IMPORTANT: Add to event loop so messages get polled!
    // The event loop only polls fds in its connections_ map
    loop_.add_connection(std::move(conn));

    // Worker is now owned by event loop, get raw pointer for local use
    Connection* conn_ptr = loop_.get_connection(client_fd);

    // Generate unique extra_nonce2 for this worker
    std::ostringstream oss;
    oss << std::hex << std::setfill('0') << std::setw(8) << next_extra_nonce2_++;
    std::string extra_nonce2 = oss.str();

    // Store worker info (with non-owning pointer)
    WorkerInfo info;
    info.conn = conn_ptr;
    info.extra_nonce2 = extra_nonce2;
    workers_[client_fd] = std::move(info);

    // Send current job if available
    if (has_job_) {
        send_job(current_job_);
    }
}

void WorkerManager::on_worker_state(Connection* conn, ConnectionState state) {
    if (!conn) return;

    int fd = conn->fd();

    switch (state) {
        case ConnectionState::ERROR:
        case ConnectionState::DISCONNECTED:
            fprintf(stderr, "[WorkerManager] Worker %d disconnected\n", fd);
            // Note: EventLoop owns the connection and will clean it up
            // We just remove our reference to it
            workers_.erase(fd);
            break;

        default:
            break;
    }
}

void WorkerManager::on_worker_message(Connection* conn, const std::string& line) {
    if (!conn) return;

    fprintf(stderr, "[WorkerManager] Worker %d: %s\n", conn->fd(), line.c_str());

    try {
        StratumRequest req = StratumRequest::parse(line);

        switch (req.method) {
            case StratumMethod::SUBSCRIBE:
                handle_subscribe(conn, req);
                break;

            case StratumMethod::AUTHORIZE:
                handle_authorize(conn, req);
                break;

            case StratumMethod::LOGIN:
                // CR29/Tari workers use Monero-style login
                handle_login(conn, req);
                break;

            case StratumMethod::SUBMIT:
            case StratumMethod::MONERO_SUBMIT:
                // Handle both Bitcoin and Monero style submit
                handle_submit(conn, req);
                break;

            default:
                fprintf(stderr, "[WorkerManager] Unknown method from worker\n");
                break;
        }
    } catch (const std::exception& e) {
        fprintf(stderr, "[WorkerManager] Failed to parse worker message: %s\n", e.what());
    }
}

void WorkerManager::handle_subscribe(Connection* conn, const StratumRequest& req) {
    int fd = conn->fd();
    auto it = workers_.find(fd);
    if (it == workers_.end()) return;

    // Build subscribe response
    // Format: [[[mining.notify, subscription ID], extra_nonce1], extra_nonce2_size]
    std::string response = R"({"id": )" + std::to_string(req.id) +
        R"(, "result": [[["mining.notify", "]" + std::to_string(fd) +
        R"("], ""], "8"], "error": null})";

    conn->send_line(response);

    it->second.subscribed = true;
    fprintf(stderr, "[WorkerManager] Worker %d subscribed\n", fd);

    // Send job if available
    if (has_job_) {
        send_job(current_job_);
    }
}

void WorkerManager::handle_authorize(Connection* conn, const StratumRequest& req) {
    int fd = conn->fd();
    auto it = workers_.find(fd);
    if (it == workers_.end()) return;

    // Extract worker_id from params
    std::string worker_id;
    if (req.params.is_array() && req.params.size() > 0) {
        worker_id = req.params[0].get<std::string>();
    }

    it->second.worker_id = worker_id;

    // Check whitelist
    bool allowed = !require_whitelist_ || is_worker_allowed(worker_id);

    // Build authorize response
    std::string response = R"({"id": )" + std::to_string(req.id) +
        R"(, "result": )" + (allowed ? "true" : "false") +
        R"(, "error": null})";

    conn->send_line(response);

    if (allowed) {
        it->second.authorized = true;
        fprintf(stderr, "[WorkerManager] Worker %s (fd=%d) authorized\n",
                worker_id.c_str(), fd);
    } else {
        fprintf(stderr, "[WorkerManager] Worker %s (fd=%d) not in whitelist\n",
                worker_id.c_str(), fd);
        it->second.conn->mark_for_closing();
    }
}

void WorkerManager::handle_login(Connection* conn, const StratumRequest& req) {
    int fd = conn->fd();
    auto it = workers_.find(fd);
    if (it == workers_.end()) return;

    // Monero-style login: {"method":"login","params":{"login":wallet,"pass":password,"agent":...},"id":1}
    std::string worker_id;
    if (req.params.is_object() && req.params.contains("login")) {
        worker_id = req.params["login"];
    }

    it->second.worker_id = worker_id;

    // Check whitelist
    bool allowed = !require_whitelist_ || is_worker_allowed(worker_id);

    // For Monero-style login, respond with job if available
    // Format matches Monero stratum response
    std::string response;
    if (has_job_) {
        // Include job in login response (Monero-style)
        response = R"({"id": )" + std::to_string(req.id) +
            R"(, "jsonrpc": "2.0", "result": {"id": ")" + std::to_string(fd) +
            R"(", "job": {"algo":"cuckaroo","blob":")" + current_job_.blob +
            R"(","job_id":")" + current_job_.job_id +
            R"(","target":")" + current_job_.target +
            R"(","height":)" + std::to_string(current_job_.height) +
            R"(}, "status": "OK"}, "error": null})";
    } else {
        // No job yet, just acknowledge login
        response = R"({"id": )" + std::to_string(req.id) +
            R"(, "jsonrpc": "2.0", "result": {"id": ")" + std::to_string(fd) +
            R"(", "status": "OK"}, "error": null})";
    }

    fprintf(stderr, "[WorkerManager] Sending login response: %s\n", response.c_str());
    conn->send_line(response);

    if (allowed) {
        it->second.subscribed = true;  // Login counts as subscribe for Monero
        it->second.authorized = true;
        fprintf(stderr, "[WorkerManager] Worker %s (fd=%d) logged in (Monero-style)\n",
                worker_id.c_str(), fd);
    } else {
        fprintf(stderr, "[WorkerManager] Worker %s (fd=%d) not in whitelist\n",
                worker_id.c_str(), fd);
        it->second.conn->mark_for_closing();
    }
}

void WorkerManager::handle_submit(Connection* conn, const StratumRequest& req) {
    int fd = conn->fd();
    auto it = workers_.find(fd);
    if (it == workers_.end()) return;

    std::string worker_id, job_id, nonce, result;

    if (req.method == StratumMethod::MONERO_SUBMIT && req.params.is_object()) {
        // Monero-style submit: {"method":"submit","params":{"id":worker,"job_id":...,"nonce":...,"result":...},"id":2}
        if (req.params.contains("id")) worker_id = req.params["id"];
        if (req.params.contains("job_id")) job_id = req.params["job_id"];
        if (req.params.contains("nonce")) nonce = req.params["nonce"];
        if (req.params.contains("result")) result = req.params["result"];
    } else if (req.params.is_array() && req.params.size() >= 4) {
        // Bitcoin-style submit: ["worker", "job_id", "nonce", "result"]
        worker_id = req.params[0];
        job_id = req.params[1];
        nonce = req.params[2];
        result = req.params[3];
    }

    fprintf(stderr, "[WorkerManager] Share from %s: job=%s nonce=%s\n",
            worker_id.c_str(), job_id.c_str(), nonce.c_str());

    // Send immediate acknowledgment (share accepted)
    // Monero Stratum submit response format: result should be boolean true for accepted
    std::string response = R"({"id": )" + std::to_string(req.id) +
        R"(, "jsonrpc": "2.0", "result": true})";
    conn->send_line(response);

    // Forward to pool via callback
    if (share_cb_) {
        share_cb_(worker_id, job_id, nonce, result);
    }
}

bool WorkerManager::is_worker_allowed(const std::string& worker_id) {
    if (!require_whitelist_) return true;

    for (const auto& config : worker_configs_) {
        if (config.id == worker_id) return true;
    }
    return false;
}

void WorkerManager::send_job(const Job& job) {
    current_job_ = job;
    has_job_ = true;

    if (workers_.empty()) {
        return;
    }

    // Build mining.notify message
    // Format: ["job_id", "extra_nonce2", "target", "difficulty", height, clean_jobs]
    // Note: extra_nonce2 varies per worker
    std::string msg = R"({"id": null, "method": "mining.notify", "params": [")" +
        job.job_id + R"(", ")" +
        R"(", ")" +  // extra_nonce1 (empty for CR29)
        job.target + R"(", ")" +
        job.difficulty + R"(, )" +
        std::to_string(job.height) + R"(, )" +
        (job.clean_jobs ? "true" : "false") + R"(]})";

    // The message above needs extra_nonce2 inserted
    // Let's rebuild it properly:
    // notify params: [job_id, blob, target, difficulty, height, clean_jobs]
    // blob = extra_nonce1 + extra_nonce2 (per worker)

    for (auto& [fd, info] : workers_) {
        if (!info.subscribed || !info.authorized) continue;

        // Monero Stratum job notification format
        // Format: {"jsonrpc":"2.0","method":"job","params":{"algo":"cuckaroo","blob":"...","job_id":"...","target":"...","height":...}}
        std::string notify = R"({"jsonrpc":"2.0", "method": "job", "params": {"algo": "cuckaroo", "blob": ")" +
            job.blob + R"(", "job_id": ")" + job.job_id + R"(", "target": ")" + job.target +
            R"(", "height": )" + std::to_string(job.height) + R"(}})";

        info.conn->send_line(notify);
    }

    fprintf(stderr, "[WorkerManager] Sent job %s to %zu workers\n",
            job.job_id.c_str(), workers_.size());
}

void WorkerManager::send_response(int worker_fd, const std::string& response) {
    auto it = workers_.find(worker_fd);
    if (it != workers_.end()) {
        it->second.conn->send_line(response);
    }
}

} // namespace gpu_proxy
