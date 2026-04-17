#include "stratum.hpp"
#include <sstream>
#include <algorithm>

namespace gpu_proxy {

StratumRequest StratumRequest::parse(const std::string& line) {
    StratumRequest req;

    try {
        nlohmann::json j = nlohmann::json::parse(line);

        if (j.contains("id")) j["id"].get_to(req.id);
        else req.id = 0;  // Notifications have no id

        if (j.contains("method")) {
            std::string method_str;
            j["method"].get_to(method_str);

            if (method_str == "mining.subscribe") req.method = StratumMethod::SUBSCRIBE;
            else if (method_str == "mining.authorize") req.method = StratumMethod::AUTHORIZE;
            else if (method_str == "mining.submit") req.method = StratumMethod::SUBMIT;
            else if (method_str == "mining.notify") req.method = StratumMethod::NOTIFY;
            else if (method_str == "mining.set_difficulty") req.method = StratumMethod::SET_DIFFICULTY;
            // Monero Stratum protocol methods
            else if (method_str == "login") req.method = StratumMethod::LOGIN;
            else if (method_str == "job") req.method = StratumMethod::JOB;
            else if (method_str == "submit") req.method = StratumMethod::MONERO_SUBMIT;
            else req.method = StratumMethod::UNKNOWN;
        } else {
            req.method = StratumMethod::UNKNOWN;
        }

        if (j.contains("params")) {
            j["params"].get_to(req.params);
        }

    } catch (const nlohmann::json::exception& e) {
        req.method = StratumMethod::UNKNOWN;
    }

    return req;
}

std::string StratumResponse::to_json() const {
    nlohmann::json j;
    j["id"] = id;
    j["result"] = result;
    j["error"] = error;
    return j.dump();
}

Job Job::from_notify(const nlohmann::json& params) {
    Job job;
    job.height = 0;
    job.clean_jobs = false;

    if (params.is_array() && params.size() >= 4) {
        job.job_id = params[0];
        job.blob = params[1];  // Extra nonce2
        job.target = params[2];
        job.difficulty = params[3];

        if (params.size() >= 5) {
            params[4].get_to(job.height);
        }

        if (params.size() >= 6) {
            params[5].get_to(job.clean_jobs);
        }
    }

    return job;
}

} // namespace gpu_proxy
