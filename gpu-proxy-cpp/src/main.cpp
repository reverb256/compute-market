#include <iostream>
#include <csignal>
#include <unistd.h>
#include "config.hpp"
#include "event_loop.hpp"
#include "pool_manager.hpp"
#include "worker_manager.hpp"

using namespace gpu_proxy;

// Global flag for graceful shutdown
static volatile bool running = true;

void signal_handler(int signum) {
    std::cout << "\n[gpu-proxy] Received signal " << signum << ", shutting down..." << std::endl;
    running = false;
}

class GPUProxy {
public:
    GPUProxy(const std::string& config_path)
        : config_(ConfigLoader::load_from_file(config_path)),
          loop_(std::make_unique<EventLoop>()),
          pool_manager_(nullptr),
          worker_manager_(nullptr) {
    }

    ~GPUProxy() = default;

    bool start() {
        std::cout << "[gpu-proxy] Starting GPU Proxy v2.0.0" << std::endl;
        std::cout << "[gpu-proxy] Loaded " << config_.pools.size() << " pools" << std::endl;

        if (config_.pools.empty()) {
            std::cerr << "[gpu-proxy] ERROR: No pools configured" << std::endl;
            return false;
        }

        // Create pool manager
        pool_manager_ = std::make_unique<PoolManager>(*loop_, config_.pools);

        // Create worker manager
        worker_manager_ = std::make_unique<WorkerManager>(
            *loop_,
            config_.listen_port,
            config_.workers
        );

        // Wire up callbacks

        // Pool -> Worker: Job distribution
        pool_manager_->set_job_callback([this](const Job& job) {
            std::cout << "[gpu-proxy] Received job " << job.job_id
                      << ", distributing to " << worker_manager_->worker_count()
                      << " workers" << std::endl;
            worker_manager_->send_job(job);
        });

        // Pool -> Share response forwarding to worker
        pool_manager_->set_share_response_callback([this](const std::string& worker_id,
                                                         bool accepted,
                                                         const std::string& error) {
            std::cout << "[gpu-proxy] Share response for " << worker_id
                      << ": accepted=" << accepted
                      << " error=" << error << std::endl;
            // NOTE: Worker-to-share tracking is now implemented in PoolManager
            // To complete: Add WorkerManager::send_share_response(worker_id, accepted, error)
            // which would look up worker_fd and send the response message
        });

        // Pool state changes
        pool_manager_->set_state_callback([this](const std::string& pool_name, bool connected) {
            std::cout << "[gpu-proxy] Pool " << pool_name
                      << " is now " << (connected ? "CONNECTED" : "DISCONNECTED")
                      << std::endl;
        });

        // Worker -> Pool: Share submission
        worker_manager_->set_share_callback([this](const std::string& worker_id,
                                                    const std::string& job_id,
                                                    const std::string& nonce,
                                                    const std::string& result) {
            std::cout << "[gpu-proxy] Submitting share from " << worker_id
                      << " job=" << job_id << " nonce=" << nonce << std::endl;
            pool_manager_->submit_share(worker_id, job_id, nonce, result);
        });

        // Start pool connections
        pool_manager_->start();

        // Start listening for workers
        worker_manager_->start();

        std::cout << "[gpu-proxy] Ready, listening on port " << config_.listen_port << std::endl;
        return true;
    }

    void run() {
        loop_->run();
    }

    void stop() {
        if (loop_) {
            loop_->stop();
        }
    }

private:
    ProxyConfig config_;
    std::unique_ptr<EventLoop> loop_;
    std::unique_ptr<PoolManager> pool_manager_;
    std::unique_ptr<WorkerManager> worker_manager_;
};

int main(int argc, char* argv[]) {
    std::string config_path = "/etc/gpu-proxy/config.json";

    // Parse command line
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--config" && i + 1 < argc) {
            config_path = argv[++i];
        } else if (std::string(argv[i]) == "--help" || std::string(argv[i]) == "-h") {
            std::cout << "GPU Proxy v2.0.0 - C++ Stratum Mining Proxy\n"
                      << "Usage: " << argv[0] << " [--config PATH]\n"
                      << "\nOptions:\n"
                      << "  --config PATH  Path to config file (default: /etc/gpu-proxy/config.json)\n"
                      << "  --help, -h     Show this help message\n"
                      << std::endl;
            return 0;
        }
    }

    // Set up signal handlers
    struct sigaction action {};
    action.sa_handler = signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(SIGINT, &action, nullptr);
    sigaction(SIGTERM, &action, nullptr);

    try {
        GPUProxy proxy(config_path);

        if (!proxy.start()) {
            return 1;
        }

        // Run until signal
        while (running) {
            proxy.run();
            break;  // Event loop exited
        }

        proxy.stop();
        std::cout << "[gpu-proxy] Shutdown complete" << std::endl;
        return 0;

    } catch (const std::exception& e) {
        std::cerr << "[gpu-proxy] ERROR: " << e.what() << std::endl;
        return 1;
    }
}
