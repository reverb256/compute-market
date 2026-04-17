#include "config.hpp"
#include <fstream>
#include <stdexcept>
#include <nlohmann/json.hpp>
#include <sstream>

namespace gpu_proxy {

// Helper to parse "host:port" string
static void parse_host_port(const std::string& url, std::string& host, uint16_t& port) {
    size_t colon_pos = url.find(':');
    if (colon_pos != std::string::npos) {
        host = url.substr(0, colon_pos);
        std::string port_str = url.substr(colon_pos + 1);
        std::istringstream iss(port_str);
        iss >> port;
    } else {
        host = url;
        port = 3333;  // Default stratum port
    }
}

ProxyConfig ConfigLoader::load_from_file(const std::string& path) {
    std::ifstream file(path);
    if (!file) {
        throw std::runtime_error("Cannot open config file: " + path);
    }

    nlohmann::json j;
    file >> j;

    ProxyConfig config;

    // Parse settings
    if (j.contains("settings")) {
        const auto& settings = j["settings"];
        if (settings.contains("listen_port")) settings["listen_port"].get_to(config.listen_port);
        if (settings.contains("api_port")) settings["api_port"].get_to(config.api_port);
        if (settings.contains("log_level")) settings["log_level"].get_to(config.log_level);
    }

    // Parse pools
    if (j.contains("pools")) {
        for (const auto& p : j["pools"]) {
            PoolConfig pool;
            p["name"].get_to(pool.name);
            std::string url;
            p["url"].get_to(url);
            parse_host_port(url, pool.host, pool.port);
            p["wallet"].get_to(pool.wallet);
            p["password"].get_to(pool.password);
            p["tls"].get_to(pool.tls);
            p["priority"].get_to(pool.priority);
            config.pools.push_back(pool);
        }
    }

    // Parse workers
    if (j.contains("workers")) {
        for (const auto& w : j["workers"]) {
            WorkerConfig worker;
            w["id"].get_to(worker.id);
            w["password"].get_to(worker.password);
            config.workers.push_back(worker);
        }
    }

    return config;
}

ProxyConfig ConfigLoader::load_default() {
    ProxyConfig config;
    config.listen_port = 3334;
    config.api_port = 8083;
    config.log_level = "INFO";
    return config;
}

} // namespace gpu_proxy
