#pragma once
#include <string>
#include <functional>
#include <memory>
#include <cstdint>

// Include OpenSSL headers directly
#include <openssl/ssl.h>

namespace gpu_proxy {

enum class ConnectionState {
    DISCONNECTED,
    CONNECTING,
    CONNECTED,
    AUTHENTICATED,
    ERROR
};

enum class ConnectionType {
    POOL,      // Outgoing TLS connection to mining pool
    WORKER     // Incoming plain TCP connection from miner
};

// Callback for when a complete line is received
using MessageCallback = std::function<void(const std::string& line)>;
// Callback for connection state changes
using StateCallback = std::function<void(ConnectionState state)>;

class Connection {
public:
    Connection(int fd, ConnectionType type, const std::string& name);
    ~Connection();

    // Non-copyable, movable
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;
    Connection(Connection&& other) noexcept;
    Connection& operator=(Connection&& other) noexcept;

    // Getters
    int fd() const { return fd_; }
    ConnectionState state() const { return state_; }
    const std::string& name() const { return name_; }
    ConnectionType type() const { return type_; }
    bool is_connected() const { return state_ >= ConnectionState::CONNECTED; }

    // TLS setup for pool connections
    bool setup_tls(const std::string& pool_host);
    bool perform_tls_handshake();

    // I/O operations
    bool send_line(const std::string& line);
    ssize_t read_data();

    // Callbacks
    void set_message_callback(MessageCallback cb) { message_cb_ = std::move(cb); }
    void set_state_callback(StateCallback cb) { state_cb_ = std::move(cb); }

    // State management
    void set_state(ConnectionState state);
    void mark_for_closing() { should_close_ = true; }
    bool should_close() const { return should_close_; }

    // For non-blocking TLS operations
    bool tls_handshake_pending() const;
    bool continue_tls_handshake();

    // Check if TLS handshake is waiting for read or write
    bool tls_waiting_for_read() const;
    bool tls_waiting_for_write() const;

private:
    struct Impl;
    std::unique_ptr<Impl> pimpl_;

    int fd_;
    ConnectionType type_;
    std::string name_;
    ConnectionState state_;

    // Read buffer
    std::string read_buffer_;
    static constexpr size_t BUFFER_SIZE = 8192;

    // Callbacks
    MessageCallback message_cb_;
    StateCallback state_cb_;

    // Flags
    bool should_close_ = false;

    // Internal methods
    void process_read_buffer();
    bool create_ssl_context();
};

// Factory for creating outgoing TLS connections to pools
std::unique_ptr<Connection> connect_to_pool(
    const std::string& host,
    uint16_t port,
    const std::string& name
);

} // namespace gpu_proxy
