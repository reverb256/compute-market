#include "connection.hpp"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <cstdio>
#include <cerrno>

namespace gpu_proxy {

// PIMPL implementation struct
struct Connection::Impl {
    SSL* ssl = nullptr;
    SSL_CTX* ctx = nullptr;
    std::string sni_hostname;
    bool tls_handshake_complete = false;
    bool tls_want_read = false;   // Handshake waiting for read
    bool tls_want_write = false;  // Handshake waiting for write
    bool ssl_fd_attached = false; // SSL_set_fd() called
};

// ============================================================================
// Connection Implementation
// ============================================================================

Connection::Connection(int fd, ConnectionType type, const std::string& name)
    : pimpl_(std::make_unique<Impl>()), fd_(fd), type_(type), name_(name),
      state_(ConnectionState::DISCONNECTED) {
    if (type == ConnectionType::WORKER) {
        // Workers start as connected (accepted from listening socket)
        set_state(ConnectionState::CONNECTED);
    } else {
        // Pool connections need to go through connect() and TLS handshake
        set_state(ConnectionState::CONNECTING);
    }

    // Set non-blocking mode
    int flags = fcntl(fd_, F_GETFL, 0);
    if (flags == -1 || fcntl(fd_, F_SETFL, flags | O_NONBLOCK) == -1) {
        fprintf(stderr, "[%s] Failed to set non-blocking: %s\n",
                name_.c_str(), strerror(errno));
    }
}

Connection::~Connection() {
    if (pimpl_->ssl) {
        SSL_shutdown(pimpl_->ssl);
        SSL_free(pimpl_->ssl);
        pimpl_->ssl = nullptr;
    }
    if (pimpl_->ctx) {
        SSL_CTX_free(pimpl_->ctx);
        pimpl_->ctx = nullptr;
    }
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
}

Connection::Connection(Connection&& other) noexcept
    : pimpl_(std::move(other.pimpl_)),
      fd_(other.fd_),
      type_(other.type_),
      name_(std::move(other.name_)),
      state_(other.state_),
      read_buffer_(std::move(other.read_buffer_)),
      message_cb_(std::move(other.message_cb_)),
      state_cb_(std::move(other.state_cb_)),
      should_close_(other.should_close_) {
    other.fd_ = -1;
}

Connection& Connection::operator=(Connection&& other) noexcept {
    if (this != &other) {
        if (fd_ >= 0) close(fd_);
        if (pimpl_->ssl) SSL_free(pimpl_->ssl);
        if (pimpl_->ctx) SSL_CTX_free(pimpl_->ctx);

        pimpl_ = std::move(other.pimpl_);
        fd_ = other.fd_;
        type_ = other.type_;
        name_ = std::move(other.name_);
        state_ = other.state_;
        read_buffer_ = std::move(other.read_buffer_);
        message_cb_ = std::move(other.message_cb_);
        state_cb_ = std::move(other.state_cb_);
        should_close_ = other.should_close_;

        other.fd_ = -1;
    }
    return *this;
}

bool Connection::create_ssl_context() {
    const SSL_METHOD* method = TLS_client_method();
    pimpl_->ctx = SSL_CTX_new(method);
    if (!pimpl_->ctx) {
        fprintf(stderr, "[%s] Failed to create SSL context\n", name_.c_str());
        return false;
    }

    // Use TLS 1.2 for maximum compatibility with Kryptex
    SSL_CTX_set_min_proto_version(pimpl_->ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(pimpl_->ctx, TLS1_2_VERSION);

    // Set cipher list for compatibility
    if (SSL_CTX_set_cipher_list(pimpl_->ctx, "DEFAULT:@SECLEVEL=0") <= 0) {
        fprintf(stderr, "[%s] Failed to set cipher list\n", name_.c_str());
        SSL_CTX_free(pimpl_->ctx);
        pimpl_->ctx = nullptr;
        return false;
    }

    // Disable cert verification (pools use self-signed)
    SSL_CTX_set_verify(pimpl_->ctx, SSL_VERIFY_NONE, nullptr);

    return true;
}

bool Connection::setup_tls(const std::string& pool_host) {
    if (type_ != ConnectionType::POOL) {
        return false;  // Only pool connections use TLS
    }

    // Use the pool's hostname for SNI (not hardcoded kryptex.com)
    // This matches the Python proxy behavior
    pimpl_->sni_hostname = pool_host;

    if (!create_ssl_context()) {
        set_state(ConnectionState::ERROR);
        return false;
    }

    pimpl_->ssl = SSL_new(pimpl_->ctx);
    if (!pimpl_->ssl) {
        fprintf(stderr, "[%s] Failed to create SSL\n", name_.c_str());
        set_state(ConnectionState::ERROR);
        return false;
    }

    // Set SNI hostname
    SSL_set_tlsext_host_name(pimpl_->ssl, pimpl_->sni_hostname.c_str());

    // NOTE: We don't call SSL_set_fd() here because the TCP connection
    // hasn't completed yet. It will be attached after connect completes.

    return true;
}

bool Connection::perform_tls_handshake() {
    if (!pimpl_->ssl || pimpl_->tls_handshake_complete) {
        return pimpl_->tls_handshake_complete;
    }

    // Attach SSL to socket on first call (after TCP connect completes)
    if (!pimpl_->ssl_fd_attached) {
        if (!SSL_set_fd(pimpl_->ssl, fd_)) {
            fprintf(stderr, "[%s] Failed to set SSL fd\n", name_.c_str());
            set_state(ConnectionState::ERROR);
            should_close_ = true;
            return false;
        }
        pimpl_->ssl_fd_attached = true;
    }

    // Reset want flags before attempting handshake
    pimpl_->tls_want_read = false;
    pimpl_->tls_want_write = false;

    int ret = SSL_connect(pimpl_->ssl);
    if (ret == 1) {
        // Handshake complete
        pimpl_->tls_handshake_complete = true;
        pimpl_->tls_want_read = false;
        pimpl_->tls_want_write = false;
        set_state(ConnectionState::CONNECTED);
        fprintf(stderr, "[%s] TLS handshake complete\n", name_.c_str());
        return true;
    }

    int err = SSL_get_error(pimpl_->ssl, ret);
    if (err == SSL_ERROR_WANT_READ) {
        pimpl_->tls_want_read = true;
        return false;
    }
    if (err == SSL_ERROR_WANT_WRITE) {
        pimpl_->tls_want_write = true;
        return false;
    }

    // Actual error - dump more info
    unsigned long err_code = ERR_get_error();
    char err_buf[256];
    ERR_error_string_n(err_code, err_buf, sizeof(err_buf));
    fprintf(stderr, "[%s] TLS handshake failed: SSL_error=%d, ERR=%lu: %s\n",
            name_.c_str(), err, err_code, err_buf);
    set_state(ConnectionState::ERROR);
    should_close_ = true;
    return false;
}

bool Connection::tls_handshake_pending() const {
    return pimpl_->ssl != nullptr && !pimpl_->tls_handshake_complete;
}

bool Connection::tls_waiting_for_read() const {
    return tls_handshake_pending() && pimpl_->tls_want_read;
}

bool Connection::tls_waiting_for_write() const {
    return tls_handshake_pending() && pimpl_->tls_want_write;
}

bool Connection::continue_tls_handshake() {
    return perform_tls_handshake();
}

bool Connection::send_line(const std::string& line) {
    if (!is_connected() && !pimpl_->tls_handshake_complete) {
        fprintf(stderr, "[%s] send_line rejected: not connected (state=%d, tls_complete=%d)\n",
                name_.c_str(), static_cast<int>(state_), pimpl_->tls_handshake_complete);
        return false;
    }

    std::string full_line = line + "\n";
    int sent;

    if (pimpl_->ssl) {
        sent = SSL_write(pimpl_->ssl, full_line.c_str(), full_line.length());
    } else {
        sent = write(fd_, full_line.c_str(), full_line.length());
    }

    if (sent <= 0) {
        if (pimpl_->ssl) {
            int err = SSL_get_error(pimpl_->ssl, sent);
            fprintf(stderr, "[%s] SSL_write error: %d\n", name_.c_str(), err);
            if (err == SSL_ERROR_WANT_WRITE || err == SSL_ERROR_WANT_READ) {
                return true;  // Try again later
            }
        }
        fprintf(stderr, "[%s] Send failed: %s\n", name_.c_str(), strerror(errno));
        should_close_ = true;
        return false;
    }

    return static_cast<size_t>(sent) == full_line.length();
}

ssize_t Connection::read_data() {
    // Don't read if TLS handshake is pending
    if (tls_handshake_pending()) {
        return 0;
    }

    char buf[BUFFER_SIZE];
    ssize_t received;

    if (pimpl_->ssl) {
        received = SSL_read(pimpl_->ssl, buf, sizeof(buf) - 1);
        if (received <= 0) {
            int err = SSL_get_error(pimpl_->ssl, received);
            if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
                return 0;  // No data available now
            }
            if (err == SSL_ERROR_ZERO_RETURN) {
                // Clean shutdown
                fprintf(stderr, "[%s] Connection closed by peer\n", name_.c_str());
            } else {
                fprintf(stderr, "[%s] SSL_read error: %d\n", name_.c_str(), err);
            }
            should_close_ = true;
            return -1;
        }
    } else {
        received = read(fd_, buf, sizeof(buf) - 1);
        if (received <= 0) {
            if (received < 0 && errno == EAGAIN) {
                return 0;  // No data available
            }
            if (received == 0) {
                fprintf(stderr, "[%s] Connection closed by peer\n", name_.c_str());
            } else {
                fprintf(stderr, "[%s] Read error: %s\n", name_.c_str(), strerror(errno));
            }
            should_close_ = true;
            return -1;
        }
    }

    buf[received] = '\0';
    read_buffer_.append(buf, received);

    // Process complete lines
    process_read_buffer();

    return received;
}

void Connection::process_read_buffer() {
    size_t newline_pos;
    while ((newline_pos = read_buffer_.find('\n')) != std::string::npos) {
        std::string line = read_buffer_.substr(0, newline_pos);

        // Remove carriage return if present
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }

        read_buffer_.erase(0, newline_pos + 1);

        // Invoke callback if set
        if (message_cb_) {
            message_cb_(line);
        }
    }
}

void Connection::set_state(ConnectionState state) {
    if (state_ != state) {
        state_ = state;
        if (state_cb_) {
            state_cb_(state);
        }
    }
}

// ============================================================================
// Factory Functions
// ============================================================================

std::unique_ptr<Connection> connect_to_pool(
    const std::string& host,
    uint16_t port,
    const std::string& name
) {
    // Create socket
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "[%s] Failed to create socket: %s\n",
                name.c_str(), strerror(errno));
        return nullptr;
    }

    // Set non-blocking
    int flags = fcntl(fd, F_GETFL, 0);
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(fd);
        return nullptr;
    }

    // Resolve hostname
    struct addrinfo hints{}, *result;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    int ret = getaddrinfo(host.c_str(), nullptr, &hints, &result);
    if (ret != 0) {
        fprintf(stderr, "[%s] Failed to resolve %s: %s\n",
                name.c_str(), host.c_str(), gai_strerror(ret));
        close(fd);
        return nullptr;
    }

    // Set port
    ((struct sockaddr_in*)(result->ai_addr))->sin_port = htons(port);

    // Start connect (non-blocking, so may return EINPROGRESS)
    ret = connect(fd, result->ai_addr, result->ai_addrlen);
    freeaddrinfo(result);

    if (ret < 0 && errno != EINPROGRESS) {
        fprintf(stderr, "[%s] Connect failed: %s\n", name.c_str(), strerror(errno));
        close(fd);
        return nullptr;
    }

    auto conn = std::make_unique<Connection>(fd, ConnectionType::POOL, name);

    // Setup TLS (will complete handshake later)
    if (!conn->setup_tls(host)) {
        return nullptr;
    }

    return conn;
}

} // namespace gpu_proxy
