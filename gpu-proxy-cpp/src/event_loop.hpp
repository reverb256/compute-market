#pragma once
#include "connection.hpp"
#include <memory>
#include <unordered_map>
#include <functional>
#include <cstdint>

namespace gpu_proxy {

// Forward declarations
class PoolManager;
class WorkerManager;

class EventLoop {
public:
    EventLoop();
    ~EventLoop();

    // Non-copyable, non-movable
    EventLoop(const EventLoop&) = delete;
    EventLoop& operator=(const EventLoop&) = delete;

    // Add a connection to the event loop
    void add_connection(std::unique_ptr<Connection> conn);
    void remove_connection(int fd);

    // Get connection by fd
    Connection* get_connection(int fd);

    // Run the event loop (blocking)
    void run();

    // Stop the event loop
    void stop() { running_ = false; }

    // Check if running
    bool is_running() const { return running_; }

    // Get current time
    uint64_t now_ms() const;

    // Set timeout callbacks
    using TimeoutCallback = std::function<void()>;
    void set_timeout(uint64_t interval_ms, TimeoutCallback cb, bool recurring = false);

private:
    // Poll file descriptors and handle events
    void poll_and_process(int timeout_ms);

    // Handle read event on a connection
    void handle_read_event(Connection* conn);

    // Handle write event on a connection
    void handle_write_event(Connection* conn);

    // Clean up closed connections
    void cleanup_closed();

    // Check and execute timeouts
    void check_timeouts();

    struct Timeout {
        uint64_t next_fire_ms;
        uint64_t interval_ms;
        TimeoutCallback callback;
        bool recurring = false;  // If false, remove after firing
    };

    // File descriptor to connection mapping
    std::unordered_map<int, std::unique_ptr<Connection>> connections_;

    // Timeouts
    std::vector<Timeout> timeouts_;

    // Running state
    bool running_ = false;

    // Timeout for poll when there are active timeouts
    static constexpr int IDLE_POLL_MS = 1000;
};

} // namespace gpu_proxy
