#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace gpu_proxy {

struct PoolConfig {
    std::string name;
    std::string host;
    uint16_t port;
    std::string wallet;
    std::string password;
    bool tls;
    int priority;
};

struct WorkerConfig {
    std::string id;
    std::string password;
};

struct ProxyConfig {
    uint16_t listen_port;
    uint16_t api_port;
    std::string log_level;
    std::vector<PoolConfig> pools;
    std::vector<WorkerConfig> workers;
};

class ConfigLoader {
public:
    static ProxyConfig load_from_file(const std::string& path);
    static ProxyConfig load_default();  // For testing
};

} // namespace gpu_proxy
