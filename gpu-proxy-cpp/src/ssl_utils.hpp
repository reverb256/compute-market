#pragma once
#include <string>
#include <cstdint>

struct ssl_st;  // Forward declare SSL
typedef struct ssl_st SSL;

struct ssl_ctx_st;  // Forward declare SSL_CTX
typedef struct ssl_ctx_st SSL_CTX;

struct ssl_st;  // Forward declare SSL
typedef struct ssl_st SSL;

namespace gpu_proxy {

class TLSConnection {
public:
    TLSConnection(const std::string& host, uint16_t port);
    ~TLSConnection();

    bool connect();
    void disconnect();
    bool is_connected() const { return connected_; }

    // Send line (adds newline)
    bool send_line(const std::string& line);

    // Receive line (reads until newline)
    std::string recv_line(int timeout_sec = 30);

private:
    std::string host_;
    uint16_t port_;
    int socket_fd_ = -1;
    SSL* ssl_ = nullptr;
    SSL_CTX* ctx_ = nullptr;
    bool connected_ = false;

    bool create_ssl_context();
    bool perform_ssl_handshake();
};

} // namespace gpu_proxy
