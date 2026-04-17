#pragma once
#include <string>
#include <cstdint>
#include <nlohmann/json.hpp>

namespace gpu_proxy {

enum class StratumMethod {
    SUBSCRIBE,
    AUTHORIZE,
    SUBMIT,
    NOTIFY,
    SET_DIFFICULTY,
    // Monero Stratum protocol methods
    LOGIN,
    JOB,
    MONERO_SUBMIT,
    UNKNOWN
};

struct StratumRequest {
    int id;
    StratumMethod method;
    nlohmann::json params;

    static StratumRequest parse(const std::string& line);
};

struct StratumResponse {
    int id;
    nlohmann::json result;
    nlohmann::json error;

    std::string to_json() const;
};

struct Job {
    std::string job_id;
    std::string blob;
    std::string target;
    std::string difficulty;
    uint64_t height;
    bool clean_jobs;

    static Job from_notify(const nlohmann::json& params);
};

} // namespace gpu_proxy
