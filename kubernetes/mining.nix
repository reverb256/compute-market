{
  pkgs,
  config,
  lib,
  ...
}:
let
  nixCsiScratch = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
in
{
  config.kubernetes.objects = {
    none.Namespace.mining = {
      metadata.labels = {
        name = "mining";
        workload = "crypto-mining";
      };
    };

    mining.ServiceAccount.gpu-miner-sa = { };
    mining.Role.gpu-miner-role = {
      rules = [
        {
          apiGroups = [ "" ];
          resources = [ "configmaps" ];
          verbs = [
            "get"
            "list"
          ];
        }
      ];
    };
    mining.RoleBinding.gpu-miner-rolebinding = {
      subjects = [
        {
          kind = "ServiceAccount";
          name = "gpu-miner-sa";
          namespace = "mining";
        }
      ];
      roleRef = {
        kind = "Role";
        name = "gpu-miner-role";
        apiGroup = "rbac.authorization.k8s.io";
      };
    };


    mining.NetworkPolicy.default-deny-all = {
      spec = {
        podSelector = { };
        policyTypes = [
          "Ingress"
          "Egress"
        ];
      };
    };
    mining.NetworkPolicy.xmrig-proxy-policy = {
      spec = {
        podSelector.matchLabels.app = "xmrig-proxy";
        policyTypes = [
          "Ingress"
          "Egress"
        ];
        ingress = [
          {
            from = [
              { namespaceSelector.matchLabels.name = "mining"; }
              { podSelector = { }; }
            ];
            ports = [
              {
                protocol = "TCP";
                port = 3333;
              }
            ];
          }
          {
            from = [ { namespaceSelector.matchLabels.name = "monitoring"; } ];
            ports = [
              {
                protocol = "TCP";
                port = 8081;
              }
            ];
          }
        ];
        egress = [
          {
            to = [ { namespaceSelector = { }; } ];
            ports = [
              {
                protocol = "UDP";
                port = 53;
              }
              {
                protocol = "TCP";
                port = 53;
              }
            ];
          }
          {
            to = [
              {
                ipBlock = {
                  cidr = "0.0.0.0/0";
                  except = [
                    "10.0.0.0/8"
                    "172.16.0.0/12"
                    "192.168.0.0/16"
                  ];
                };
              }
            ];
            ports = [
              {
                protocol = "TCP";
                port = 443;
              }
              {
                protocol = "TCP";
                port = 8038;
              }
              {
                protocol = "TCP";
                port = 8040;
              }
            ];
          }
        ];
      };
    };
    mining.NetworkPolicy.xmrig-miner-policy = {
      spec = {
        podSelector.matchLabels.app = "xmrig";
        policyTypes = [ "Egress" ];
        egress = [
          {
            to = [ { podSelector.matchLabels.app = "xmrig-proxy"; } ];
            ports = [
              {
                protocol = "TCP";
                port = 3333;
              }
            ];
          }
          {
            to = [ { ipBlock.cidr = "10.1.1.0/24"; } ];
            ports = [
              {
                protocol = "TCP";
                port = 3333;
              }
            ];
          }
          {
            to = [ { namespaceSelector = { }; } ];
            ports = [
              {
                protocol = "UDP";
                port = 53;
              }
              {
                protocol = "TCP";
                port = 53;
              }
            ];
          }
        ];
      };
    };
    mining.NetworkPolicy.gpu-miner-policy = {
      spec = {
        podSelector.matchLabels.app = "gpu-miner";
        policyTypes = [ "Egress" ];
        egress = [
          {
            to = [ { podSelector.matchLabels.app = "xmrig-proxy"; } ];
            ports = [
              {
                protocol = "TCP";
                port = 3333;
              }
            ];
          }
          {
            to = [ { ipBlock.cidr = "10.1.1.0/24"; } ];
            ports = [
              {
                protocol = "TCP";
                port = 3333;
              }
            ];
          }
          {
            to = [ { namespaceSelector = { }; } ];
            ports = [
              {
                protocol = "UDP";
                port = 53;
              }
              {
                protocol = "TCP";
                port = 53;
              }
            ];
          }
        ];
      };
    };


    mining.Deployment.xmrig-zephyr = {
      metadata = {
        labels = {
          app = "xmrig-zephyr";
          host = "zephyr";
          workload = "crypto-mining";
        };
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "8082";
          "prometheus.io/path" = "/1/summary";
        };
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 2;
        selector.matchLabels.app = "xmrig-zephyr";
        strategy.type = "Recreate";
        template = {
          metadata.labels = {
            app = "xmrig-zephyr";
            host = "zephyr";
            workload = "crypto-mining";
          };
          spec = {
            nodeName = "zephyr";
            hostNetwork = true;
            hostIPC = true;
            dnsPolicy = "ClusterFirstWithHostNet";
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            tolerations = [
              {
                key = "node-role.kubernetes.io/control-plane";
                operator = "Exists";
                effect = "NoSchedule";
              }
              {
                key = "workstation";
                operator = "Equal";
                value = "true";
                effect = "NoSchedule";
              }
              {
                key = "interactive";
                operator = "Equal";
                value = "true";
                effect = "NoExecute";
              }
              {
                key = "ram-constrained";
                operator = "Equal";
                value = "true";
                effect = "NoSchedule";
              }
            ];
            containers = {
              _namedlist = true;
              xmrig = {
                image = "docker.io/library/xmrig-alpine:6.25.0";
                args = [
                  "-o"
                  "10.1.1.120:3333"
                  "-u"
                  "zephyr-cpu"
                  "--tls=false"
                  "--threads=16"
                  "--donate-level=1"
                  "--http-enabled"
                  "--http-host=0.0.0.0"
                  "--http-port=8082"
                  "--api-worker-id=zephyr-cpu"
                ];
                env = {
                  _namedlist = true;
                };
                ports = [
                  {
                    containerPort = 8082;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "1Gi";
                    cpu = "4";
                  };
                  limits = {
                    memory = "4096Mi";
                    cpu = "8";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                  msr = {
                    mountPath = "/dev/cpu";
                  };
                  hugepages = {
                    mountPath = "/dev/hugepages";
                  };
                  sys-module-msr = {
                    mountPath = "/sys/module/msr";
                  };
                  tmp = {
                    mountPath = "/tmp";
                  };
                };
              };
            };
            volumes = {
              _namedlist = true;
              msr = {
                hostPath = {
                  path = "/dev/cpu";
                  type = "Directory";
                };
              };
              hugepages = {
                hostPath = {
                  path = "/dev/hugepages";
                  type = "Directory";
                };
              };
              sys-module-msr = {
                hostPath = {
                  path = "/sys/module/msr";
                  type = "Directory";
                };
              };
              tmp = {
                emptyDir = { };
              };
            };
          };
        };
      };
    };

    mining.Deployment.xmrig-nexus = {
      metadata = {
        labels.app = "xmrig-nexus";
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "8082";
          "prometheus.io/path" = "/1/summary";
        };
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 2;
        selector.matchLabels.app = "xmrig-nexus";
        strategy.type = "Recreate";
        template = {
          metadata.labels.app = "xmrig-nexus";
          spec = {
            nodeName = "nexus";
            hostNetwork = true;
            hostIPC = true;
            dnsPolicy = "ClusterFirstWithHostNet";
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            tolerations = [
              {
                key = "node-role.kubernetes.io/control-plane";
                operator = "Exists";
                effect = "NoSchedule";
              }
            ];
            containers = {
              _namedlist = true;
              xmrig = {
                image = "docker.io/library/xmrig-alpine:6.25.0";
                args = [
                  "-o"
                  "10.1.1.120:3333"
                  "-u"
                  "nexus-cpu"
                  "--tls=false"
                  "--threads=6"
                  "--donate-level=1"
                  "--http-enabled"
                  "--http-host=0.0.0.0"
                  "--http-port=8082"
                  "--api-worker-id=nexus-cpu"
                ];
                ports = [
                  {
                    containerPort = 8082;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "1Gi";
                    cpu = "3";
                  };
                  limits = {
                    memory = "3072Mi";
                    cpu = "6";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                  msr = {
                    mountPath = "/dev/cpu";
                  };
                  hugepages = {
                    mountPath = "/dev/hugepages";
                  };
                  sys-module-msr = {
                    mountPath = "/sys/module/msr";
                  };
                  tmp = {
                    mountPath = "/tmp";
                  };
                };
              };
            };
            volumes = {
              _namedlist = true;
              msr = {
                hostPath = {
                  path = "/dev/cpu";
                  type = "Directory";
                };
              };
              hugepages = {
                hostPath = {
                  path = "/dev/hugepages";
                  type = "Directory";
                };
              };
              sys-module-msr = {
                hostPath = {
                  path = "/sys/module/msr";
                  type = "Directory";
                };
              };
              tmp = {
                emptyDir = { };
              };
            };
          };
        };
      };
    };

    mining.Deployment.xmrig-sentry = {
      metadata = {
        labels.app = "xmrig-sentry";
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "8082";
          "prometheus.io/path" = "/1/summary";
        };
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 2;
        selector.matchLabels.app = "xmrig-sentry";
        strategy.type = "Recreate";
        template = {
          metadata.labels.app = "xmrig-sentry";
          spec = {
            nodeName = "sentry";
            hostNetwork = true;
            hostIPC = true;
            dnsPolicy = "ClusterFirstWithHostNet";
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            containers = {
              _namedlist = true;
              xmrig = {
                image = "docker.io/library/xmrig-alpine:6.25.0";
                args = [
                  "-o"
                  "10.1.1.120:3333"
                  "-u"
                  "sentry-cpu"
                  "--tls=false"
                  "--threads=8"
                  "--donate-level=1"
                  "--http-enabled"
                  "--http-host=0.0.0.0"
                  "--http-port=8082"
                  "--api-worker-id=sentry-cpu"
                ];
                ports = [
                  {
                    containerPort = 8082;
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  httpGet = {
                    path = "/1/summary";
                    port = 8082;
                  };
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "1Gi";
                    cpu = "4";
                  };
                  limits = {
                    memory = "3072Mi";
                    cpu = "8";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                  msr = {
                    mountPath = "/dev/cpu";
                  };
                  hugepages = {
                    mountPath = "/dev/hugepages";
                  };
                  sys-module-msr = {
                    mountPath = "/sys/module/msr";
                  };
                  tmp = {
                    mountPath = "/tmp";
                  };
                };
              };
            };
            volumes = {
              _namedlist = true;
              msr = {
                hostPath = {
                  path = "/dev/cpu";
                  type = "Directory";
                };
              };
              hugepages = {
                hostPath = {
                  path = "/dev/hugepages";
                  type = "Directory";
                };
              };
              sys-module-msr = {
                hostPath = {
                  path = "/sys/module/msr";
                  type = "Directory";
                };
              };
              tmp = {
                emptyDir = { };
              };
            };
          };
        };
      };
    };

    mining.ConfigMap.xmrig-proxy-config = {
      metadata.labels = {
        app = "xmrig-proxy";
        component = "stratum-proxy";
      };
      data."config.json" = builtins.toJSON {
        bind = [
          {
            host = "0.0.0.0";
            port = 3333;
          }
        ];
        api = {
          port = 8081;
          restricted = true;
          "token-file" = "/etc/xmrig-proxy-secrets/api-token";
        };
        randomx.mode = "light";
        log.level = 5;
        pools = [
          {
            id = "kryptex-rx-us";
            url = "xtm-rx-us.kryptex.network:8038";
            user = "krxXVNVMM7.cpu-proxy";
            "pass-file" = "/etc/xmrig-proxy-secrets/pool-password";
            tls = true;
            keepalive = true;
            priority = 1;
          }
          {
            id = "kryptex-rx-eu";
            url = "xtm-rx-eu.kryptex.network:8038";
            user = "krxXVNVMM7.cpu-proxy";
            "pass-file" = "/etc/xmrig-proxy-secrets/pool-password";
            tls = true;
            keepalive = true;
            priority = 2;
          }
          {
            id = "kryptex-cr29-us";
            url = "xtm-c29-us.kryptex.network:8040";
            user = "krxXVNVMM7.gpu-proxy";
            "pass-file" = "/etc/xmrig-proxy-secrets/pool-password";
            tls = true;
            keepalive = true;
            priority = 1;
          }
          {
            id = "kryptex-cr29-eu";
            url = "xtm-c29-eu.kryptex.network:8040";
            user = "krxXVNVMM7.gpu-proxy";
            "pass-file" = "/etc/xmrig-proxy-secrets/pool-password";
            tls = true;
            keepalive = true;
            priority = 2;
          }
        ];
        workers = [
          {
            id = "zephyr-cpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "nexus-cpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "sentry-cpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "zephyr-gpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "nexus-gpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "forge-gpu";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "forge-gpu-nvidia";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
          {
            id = "forge-gpu-amd";
            "password-file" = "/etc/xmrig-proxy-secrets/pool-password";
          }
        ];
      };
    };

    mining.Secret.xmrig-proxy-secret = {
      metadata.labels = {
        app = "xmrig-proxy";
        component = "stratum-proxy";
      };
      type = "Opaque";
      stringData = {
        "api-token" = "CHANGE-THIS-TO-A-SECURE-RANDOM-TOKEN";
        "kryptex-password" = "x";
      };
    };

    mining.Deployment.xmrig-proxy = {
      metadata = {
        labels = {
          app = "xmrig-proxy";
          component = "stratum-proxy";
        };
        annotations = {
          "prometheus.io/scrape" = "true";
          "prometheus.io/port" = "8081";
        };
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 2;
        selector.matchLabels.app = "xmrig-proxy";
        strategy = {
          type = "RollingUpdate";
          rollingUpdate = {
            maxSurge = 0;
            maxUnavailable = 1;
          };
        };
        template = {
          metadata.labels = {
            app = "xmrig-proxy";
            component = "stratum-proxy";
          };
          spec = {
            nodeName = "nexus";
            hostNetwork = true;
            serviceAccountName = "gpu-miner-sa";
            automountServiceAccountToken = false;
            priorityClassName = "system-cluster-critical";
            tolerations = [
              {
                key = "node-role.kubernetes.io/control-plane";
                operator = "Exists";
                effect = "NoSchedule";
              }
            ];
            containers = {
              _namedlist = true;
              xmrig-proxy = {
                image = "xmrig-proxy:nixos-6.24.0";
                imagePullPolicy = "Never";
                args = [
                  "--config=/etc/xmrig-proxy/config.json"
                  "--no-color"
                ];
                ports = [
                  {
                    containerPort = 3333;
                    name = "stratum";
                    protocol = "TCP";
                  }
                  {
                    containerPort = 8081;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = "stratum";
                  initialDelaySeconds = 15;
                  periodSeconds = 20;
                  timeoutSeconds = 5;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  tcpSocket.port = "stratum";
                  initialDelaySeconds = 5;
                  periodSeconds = 10;
                  timeoutSeconds = 3;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "128Mi";
                    cpu = "100m";
                  };
                  limits = {
                    memory = "1Gi";
                    cpu = "1000m";
                  };
                };
                securityContext.capabilities.drop = [ "ALL" ];
                volumeMounts = {
                  _namedlist = true;
                  config = {
                    mountPath = "/etc/xmrig-proxy";
                  };
                  secrets = {
                    mountPath = "/etc/xmrig-proxy-secrets";
                  };
                };
              };
            };
            volumes = {
              _namedlist = true;
              config.configMap.name = "xmrig-proxy-config";
              secrets = {
                secret = {
                  secretName = "xmrig-proxy-secret";
                  items = [
                    {
                      key = "api-token";
                      path = "api-token";
                    }
                    {
                      key = "kryptex-password";
                      path = "pool-password";
                    }
                  ];
                };
              };
            };
          };
        };
      };
    };

    mining.Service.xmrig-proxy = {
      metadata.labels.app = "xmrig-proxy";
      spec = {
        type = "ClusterIP";
        selector.app = "xmrig-proxy";
        sessionAffinity = "ClientIP";
        ports = [
          {
            name = "stratum";
            port = 3333;
            targetPort = 3333;
            protocol = "TCP";
          }
          {
            name = "metrics";
            port = 8081;
            targetPort = 8081;
            protocol = "TCP";
          }
        ];
      };
    };
  };
}
