#pragma once
#include "connection.hpp"
#include "stratum.hpp"
#include "config.hpp"
#include <unordered_map>
#include <string>
#include <functional>

namespace gpu_proxy {

// Forward declarations
class EventLoop;

// Callback for when a worker submits a share
using ShareSubmitCallback = std::function<void(const std::string& worker_id,
                                               const std::string& job_id,
                                               const std::string& nonce,
                                               const std::string& result)>;

class WorkerManager {
public:
    WorkerManager(EventLoop& loop, uint16_t port, const std::vector<WorkerConfig>& workers);
    ~WorkerManager();

    // Non-copyable, non-movable
    WorkerManager(const WorkerManager&) = delete;
    WorkerManager& operator=(const WorkerManager&) = delete;

    // Set callbacks
    void set_share_callback(ShareSubmitCallback cb) { share_cb_ = std::move(cb); }

    // Start listening for worker connections
    void start();

    // Broadcast a job to all connected workers
    void send_job(const Job& job);

    // Send a response to a specific worker
    void send_response(int worker_fd, const std::string& response);

    // Get worker count
    size_t worker_count() const { return workers_.size(); }

    // Get listening port
    uint16_t port() const { return listen_port_; }

private:
    // Accept new worker connection
    void accept_worker();

    // Handle message from worker
    void on_worker_message(Connection* conn, const std::string& line);

    // Handle worker state change
    void on_worker_state(Connection* conn, ConnectionState state);

    // Handle subscribe request
    void handle_subscribe(Connection* conn, const StratumRequest& req);

    // Handle authorize request
    void handle_authorize(Connection* conn, const StratumRequest& req);

    // Handle Monero-style login request (CR29/Tari)
    void handle_login(Connection* conn, const StratumRequest& req);

    // Handle share submit
    void handle_submit(Connection* conn, const StratumRequest& req);

    // Check worker whitelist
    bool is_worker_allowed(const std::string& worker_id);

    // Event loop reference
    EventLoop& loop_;

    // Listening socket
    int listen_fd_ = -1;
    uint16_t listen_port_;

    // Connected workers
    struct WorkerInfo {
        Connection* conn;  // Non-owning pointer (EventLoop owns the connection)
        std::string worker_id;
        bool subscribed = false;
        bool authorized = false;
        std::string extra_nonce2;  // Assigned to this worker
    };
    std::unordered_map<int, WorkerInfo> workers_;

    // Worker configuration
    std::vector<WorkerConfig> worker_configs_;
    bool require_whitelist_ = false;

    // Current job for new connections
    Job current_job_;
    bool has_job_ = false;

    // Extra nonce management
    uint32_t next_extra_nonce2_ = 0;

    // Callbacks
    ShareSubmitCallback share_cb_;
};

} // namespace gpu_proxy
