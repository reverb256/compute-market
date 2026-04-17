#include "pool_manager.hpp"
#include "event_loop.hpp"
#include <sstream>
#include <cstdio>

namespace gpu_proxy {

PoolManager::PoolManager(EventLoop& loop, const std::vector<PoolConfig>& pools)
    : loop_(loop), pools_(pools) {
    if (!pools_.empty()) {
        current_pool_ = pools_[0].name;
    }
}

void PoolManager::start() {
    if (pools_.empty()) {
        fprintf(stderr, "[PoolManager] No pools configured\n");
        return;
    }

    fprintf(stderr, "[PoolManager] Starting with %zu pools\n", pools_.size());
    try_connect_pool(0);
}

void PoolManager::try_connect_pool(size_t pool_index) {
    if (pool_index >= pools_.size()) {
        fprintf(stderr, "[PoolManager] No more pools to try\n");
        return;
    }

    const auto& pool = pools_[pool_index];
    current_pool_index_ = pool_index;
    current_pool_ = pool.name;

    fprintf(stderr, "[PoolManager] Connecting to %s (%s:%d)\n",
            pool.name.c_str(), pool.host.c_str(), pool.port);

    auto conn = connect_to_pool(pool.host, pool.port, "pool:" + pool.name);
    if (!conn) {
        fprintf(stderr, "[PoolManager] Failed to create connection to %s\n", pool.name.c_str());
        // Try next pool
        try_connect_pool(pool_index + 1);
        return;
    }

    // Set up callbacks
    conn->set_state_callback([this](ConnectionState state) {
        on_pool_state(state);
    });

    conn->set_message_callback([this](const std::string& line) {
        on_pool_message(line);
    });

    // Store the fd for later lookups, then transfer ownership to event loop
    pool_fd_ = conn->fd();
    pool_conn_ = conn.get();  // Store non-owning pointer
    loop_.add_connection(std::move(conn));  // Transfer ownership
}

void PoolManager::on_pool_state(ConnectionState state) {
    auto* conn = loop_.get_connection(pool_fd_);

    switch (state) {
        case ConnectionState::CONNECTED:
            fprintf(stderr, "[PoolManager] %s: Connected\n", current_pool_.c_str());
            // Send Monero-style login (not Bitcoin Stratum subscribe!)
            send_login();
            break;

        case ConnectionState::AUTHENTICATED:
            fprintf(stderr, "[PoolManager] %s: Authenticated\n", current_pool_.c_str());
            authenticated_ = true;
            connected_ = true;
            reconnect_attempts_ = 0;
            if (state_cb_) {
                state_cb_(current_pool_, true);
            }
            break;

        case ConnectionState::ERROR:
            fprintf(stderr, "[PoolManager] %s: Error state\n", current_pool_.c_str());
            // Fall through
        case ConnectionState::DISCONNECTED:
            fprintf(stderr, "[PoolManager] %s: Disconnected\n", current_pool_.c_str());
            connected_ = false;
            authenticated_ = false;
            subscribed_ = false;
            has_job_ = false;
            if (state_cb_) {
                state_cb_(current_pool_, false);
            }
            // Try next pool or reconnect
            if (reconnect_attempts_ < MAX_RECONNECT_ATTEMPTS) {
                reconnect_attempts_++;
                fprintf(stderr, "[PoolManager] Reconnect attempt %d/%d\n",
                        reconnect_attempts_, MAX_RECONNECT_ATTEMPTS);
                // Schedule reconnect
                loop_.set_timeout(RECONNECT_DELAY_MS, [this]() {
                    try_connect_pool(current_pool_index_);
                });
            } else {
                // Try next pool in list
                reconnect_attempts_ = 0;
                try_connect_pool((current_pool_index_ + 1) % pools_.size());
            }
            break;

        default:
            break;
    }
}

void PoolManager::on_pool_message(const std::string& line) {
    fprintf(stderr, "[PoolManager] %s: %s\n", current_pool_.c_str(), line.c_str());

    try {
        // Try to parse as JSON-RPC response
        auto j = nlohmann::json::parse(line);

        if (j.contains("method")) {
            // It's a notification (from pool)
            StratumRequest req = StratumRequest::parse(line);
            // Handle both Bitcoin Stratum NOTIFY and Monero Stratum JOB
            if (req.method == StratumMethod::NOTIFY || req.method == StratumMethod::JOB) {
                handle_notification(req);
            }
        } else {
            // It's a response
            StratumResponse resp;
            if (j.contains("id")) j["id"].get_to(resp.id);
            if (j.contains("result")) resp.result = j["result"];
            if (j.contains("error")) resp.error = j["error"];
            handle_response(resp);
        }
    } catch (const std::exception& e) {
        fprintf(stderr, "[PoolManager] Failed to parse message: %s\n", e.what());
    }
}

void PoolManager::send_login() {
    const auto& pool = pools_[current_pool_index_];

    // Monero-style login (NOT Bitcoin Stratum!)
    // Format: {"method":"login","params":{"login":wallet,"pass":password,"agent":"gpu-proxy/2.0"},"id":1}
    std::string msg = R"({"method":"login","params":{"login":")" + pool.wallet +
        R"(","pass":")" + pool.password +
        R"(","agent":"gpu-proxy/2.0"},"id":)" + std::to_string(get_next_id()) + R"(})";

    auto* conn = loop_.get_connection(
        pool_conn_ ? pool_fd_ : -1
    );
    if (conn && conn->send_line(msg)) {
        fprintf(stderr, "[PoolManager] Sent Monero-style login for %s\n", pool.wallet.c_str());
    }
}

void PoolManager::handle_response(const StratumResponse& resp) {
    // Check if result exists and is an object
    if (!resp.result.is_object() || resp.result.empty()) {
        return;
    }

    // Monero-style login response has job directly in result
    if (!authenticated_ && resp.result.contains("job")) {
        authenticated_ = true;
        connected_ = true;
        subscribed_ = true;  // No separate subscribe in Monero protocol

        // Extract job from Monero-style response
        // Format: {"result":{"job":{"algo":"cuckaroo","job_id":"...","blob":"...","target":"...","height":...}}}
        auto result_job = resp.result["job"];
        if (result_job.contains("job_id") && result_job.contains("blob")) {
            current_job_.job_id = result_job["job_id"];
            current_job_.blob = result_job["blob"];
            current_job_.target = result_job["target"];
            if (result_job.contains("height")) {
                current_job_.height = result_job["height"];
            }
            has_job_ = true;

            fprintf(stderr, "[PoolManager] Login successful! Received job: %s\n",
                    current_job_.job_id.c_str());

            on_pool_state(ConnectionState::AUTHENTICATED);

            // Distribute this job to workers via callback
            fprintf(stderr, "[PoolManager] Calling job callback for login job\n");
            if (job_cb_) {
                job_cb_(current_job_);
            }
            return;
        }
    }

    // Check for Monero-style status response
    if (!authenticated_ && resp.result.contains("status")) {
        std::string status = resp.result["status"];
        if (status == "OK") {
            authenticated_ = true;
            connected_ = true;
            fprintf(stderr, "[PoolManager] Login successful (status: OK)\n");
            on_pool_state(ConnectionState::AUTHENTICATED);
        } else {
            fprintf(stderr, "[PoolManager] Login failed (status: %s)\n", status.c_str());
            on_pool_state(ConnectionState::ERROR);
        }
        return;
    }

    // Share submission response
    if (authenticated_ && share_response_cb_) {
        bool accepted = (resp.error.is_null() || resp.error.empty());
        std::string error_str = resp.error.is_string() ? resp.error.get<std::string>() : "";

        // Look up which worker submitted this share
        auto it = share_to_worker_.find(resp.id);
        if (it != share_to_worker_.end()) {
            const std::string& worker_id = it->second;
            share_response_cb_(worker_id, accepted, error_str);
            // Clean up the mapping after use
            share_to_worker_.erase(it);
        } else {
            // Unknown share ID (possibly from before a restart)
            fprintf(stderr, "[PoolManager] Share response for unknown id=%d\n", resp.id);
        }
    }
}

void PoolManager::handle_notification(const StratumRequest& req) {
    // Bitcoin Stratum notify
    if (req.method == StratumMethod::NOTIFY) {
        current_job_ = Job::from_notify(req.params);
        has_job_ = true;
        fprintf(stderr, "[PoolManager] Received new job: %s\n", current_job_.job_id.c_str());

        if (job_cb_) {
            job_cb_(current_job_);
        }
    }
    // Monero Stratum job notification
    else if (req.method == StratumMethod::JOB) {
        // Monero sends: {"method":"job","params":{"algo":"cuckaroo","job_id":"...","blob":"...","target":"...","height":...}}
        if (req.params.contains("job_id") && req.params.contains("blob")) {
            current_job_.job_id = req.params["job_id"];
            current_job_.blob = req.params["blob"];
            current_job_.target = req.params["target"];
            current_job_.height = req.params["height"];
            has_job_ = true;

            fprintf(stderr, "[PoolManager] Received Monero job: %s (height: %lu)\n",
                    current_job_.job_id.c_str(), current_job_.height);

            if (job_cb_) {
                job_cb_(current_job_);
            }
        }
    }
}

void PoolManager::submit_share(const std::string& worker_id,
                               const std::string& job_id,
                               const std::string& nonce,
                               const std::string& result) {
    if (!connected_ || !has_job_) {
        fprintf(stderr, "[PoolManager] Cannot submit share: not connected or no job\n");
        return;
    }

    int id = get_next_id();
    // Track which worker submitted this share so we can route the response back
    share_to_worker_[id] = worker_id;

    const auto& pool = pools_[current_pool_index_];

    // Monero Stratum submit format: {"method":"submit","params":{"id":worker,"job_id":...,"nonce":...,"result":...},"id":N}
    // Note: For CR29/Tari, we forward the nonce as-is (worker already computed full result)
    std::string msg = R"({"id": )" + std::to_string(id) +
        R"(, "method": "submit", "params": {"id": ")" + worker_id +
        R"(", "job_id": ")" + job_id +
        R"(", "nonce": ")" + nonce +
        R"(", "result": ")" + result +
        R"("}, "jsonrpc": "2.0"})";

    auto* conn = loop_.get_connection(
        pool_conn_ ? pool_fd_ : -1
    );
    if (conn && conn->send_line(msg)) {
        fprintf(stderr, "[PoolManager] Submitted share for %s\n", worker_id.c_str());
    }
}

} // namespace gpu_proxy
