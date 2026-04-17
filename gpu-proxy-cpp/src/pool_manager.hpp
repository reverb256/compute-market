#pragma once
#include "connection.hpp"
#include "config.hpp"
#include "stratum.hpp"
#include <vector>
#include <string>
#include <functional>
#include <map>

namespace gpu_proxy {

// Forward declarations
class EventLoop;

// Callback types for pool events
using JobCallback = std::function<void(const Job& job)>;
using ShareResponseCallback = std::function<void(const std::string& worker_id, bool accepted, const std::string& error)>;
using PoolStateCallback = std::function<void(const std::string& pool_name, bool connected)>;

class PoolManager {
public:
    PoolManager(EventLoop& loop, const std::vector<PoolConfig>& pools);
    ~PoolManager() = default;

    // Set callbacks
    void set_job_callback(JobCallback cb) { job_cb_ = std::move(cb); }
    void set_share_response_callback(ShareResponseCallback cb) { share_response_cb_ = std::move(cb); }
    void set_state_callback(PoolStateCallback cb) { state_cb_ = std::move(cb); }

    // Start connecting to pools
    void start();

    // Submit a share to the current pool
    void submit_share(const std::string& worker_id,
                     const std::string& job_id,
                     const std::string& nonce,
                     const std::string& result);

    // Get current pool info
    const std::string& current_pool_name() const { return current_pool_; }
    bool is_connected() const { return connected_; }

    // Get current job
    const Job& current_job() const { return current_job_; }
    bool has_job() const { return has_job_; }

private:
    // Connection management
    void try_connect_pool(size_t pool_index);
    void on_pool_state(ConnectionState state);
    void on_pool_message(const std::string& line);

    // Stratum protocol (Monero-style for Tari/CR29)
    void send_login();
    void handle_response(const StratumResponse& resp);
    void handle_notification(const StratumRequest& req);

    // Event loop reference
    EventLoop& loop_;

    // Pool configuration
    std::vector<PoolConfig> pools_;
    size_t current_pool_index_ = 0;
    std::string current_pool_;

    // Connection (non-owning pointer - EventLoop owns it)
    Connection* pool_conn_ = nullptr;
    int pool_fd_ = -1;  // Track the fd for lookups
    bool connected_ = false;
    bool authenticated_ = false;
    bool subscribed_ = false;

    // Current job
    Job current_job_;
    bool has_job_ = false;

    // Subscriptions
    std::string extra_nonce1_;
    std::string extra_nonce2_size_;

    // Callbacks
    JobCallback job_cb_;
    ShareResponseCallback share_response_cb_;
    PoolStateCallback state_cb_;

    // Track which worker submitted each share (id -> worker_id)
    std::map<int, std::string> share_to_worker_;

    // Next message ID
    int next_id_ = 1;
    int get_next_id() { return next_id_++; }

    // Reconnect handling
    int reconnect_attempts_ = 0;
    static constexpr int MAX_RECONNECT_ATTEMPTS = 5;
    static constexpr int RECONNECT_DELAY_MS = 5000;
};

} // namespace gpu_proxy
