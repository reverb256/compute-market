{
  pkgs,
  pkgsWithOverlay,
  config,
  lib,
  ...
}:
let
  lolminerImage = "docker.io/swamp7/lolminer:latest";
  lolminerAmdImage = "docker.io/library/lolminer-amd:1.98a-nixos";

  openclIcd = "/nix/store/6yvx83sa6iwhr6xnjjlfjg56jnki5mdn-clr-7.2.0-icd/etc/OpenCL/vendors";

  nvidiaVolumeMounts = {
    opengl-driver = {
      mountPath = "/run/opengl-driver/lib";
    };
    dev = {
      mountPath = "/dev";
    };
    nix-store = {
      mountPath = "/nix/store";
    };
  };

  nvidiaVolumes = {
    opengl-driver = {
      hostPath.path = "/run/opengl-driver/lib";
    };
    dev = {
      hostPath = {
        path = "/dev";
        type = "Directory";
      };
    };
    nix-store = {
      hostPath.path = "/nix/store";
    };
  };

  amdVolumeMounts = {
    opengl-driver = {
      mountPath = "/run/opengl-driver/lib";
    };
    dri = {
      mountPath = "/dev/dri";
    };
    kfd = {
      mountPath = "/dev/kfd";
    };
    opencl-icd = {
      mountPath = "/etc/OpenCL/vendors";
    };
    nix-store = {
      mountPath = "/nix/store";
    };
  };

  amdVolumes = {
    opengl-driver = {
      hostPath.path = "/run/opengl-driver/lib";
    };
    dri = {
      hostPath = {
        path = "/dev/dri";
        type = "Directory";
      };
    };
    kfd = {
      hostPath = {
        path = "/dev/kfd";
        type = "CharDevice";
      };
    };
    opencl-icd = {
      hostPath = {
        path = openclIcd;
        type = "Directory";
      };
    };
    nix-store = {
      hostPath.path = "/nix/store";
    };
  };

  nvidiaEnv = {
    _namedlist = true;
    LD_LIBRARY_PATH = {
      name = "LD_LIBRARY_PATH";
      value = "/run/opengl-driver/lib";
    };
  };

  amdEnv = {
    _namedlist = true;
    LD_LIBRARY_PATH = {
      name = "LD_LIBRARY_PATH";
      value = "/run/opengl-driver/lib";
    };
    OCL_ICD_VENDORS = {
      name = "OCL_ICD_VENDORS";
      value = "/etc/OpenCL/vendors/";
    };
  };

  commonArgs = [
    "--algo=CR29"
    "--pool=xtm-c29-us.kryptex.network:8040"
    "--tls=1"
    "--pool=xtm-c29-eu.kryptex.network:8040"
    "--tls=1"
  ];
in
{
  config.kubernetes.objects = {

    mining.Deployment.gpu-miner-forge-nvidia-0 = {
      metadata.labels = {
        app = "gpu-miner-forge-nvidia-0";
        "gpu-vendor" = "nvidia";
        host = "forge";
        workload = "crypto-mining";
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector.matchLabels = {
          app = "gpu-miner-forge-nvidia-0";
          "gpu-vendor" = "nvidia";
          host = "forge";
        };
        strategy.type = "Recreate";
        template = {
          metadata.labels = {
            app = "gpu-miner-forge-nvidia-0";
            "gpu-vendor" = "nvidia";
            host = "forge";
            workload = "crypto-mining";
          };
          spec = {
            nodeName = "forge";
            hostNetwork = true;
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            terminationGracePeriodSeconds = 30;
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerImage;
                args = commonArgs ++ [
                  "--user=krxXVNVMM7.forge-n0"
                  "--pass=x"
                  "--user=krxXVNVMM7.forge-n0"
                  "--pass=x"
                  "--devices=0"
                  "--apiport=4068"
                  "--cclk=2350 --moff=1100 --pl=90"
                ];
                env = nvidiaEnv;
                ports = [
                  {
                    containerPort = 4068;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = 4068;
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  tcpSocket.port = 4068;
                  initialDelaySeconds = 60;
                  periodSeconds = 15;
                  failureThreshold = 10;
                };
                resources = {
                  requests = {
                    memory = "4Gi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "8Gi";
                    cpu = "1";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                }
                // nvidiaVolumeMounts;
              };
            };
            volumes = {
              _namedlist = true;
            }
            // nvidiaVolumes;
          };
        };
      };
    };

    mining.Deployment.gpu-miner-forge-nvidia-1 = {
      metadata.labels = {
        app = "gpu-miner-forge-nvidia-1";
        "gpu-vendor" = "nvidia";
        host = "forge";
        workload = "crypto-mining";
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector.matchLabels = {
          app = "gpu-miner-forge-nvidia-1";
          "gpu-vendor" = "nvidia";
          host = "forge";
        };
        strategy.type = "Recreate";
        template = {
          metadata.labels = {
            app = "gpu-miner-forge-nvidia-1";
            "gpu-vendor" = "nvidia";
            host = "forge";
            workload = "crypto-mining";
          };
          spec = {
            nodeName = "forge";
            hostNetwork = true;
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            terminationGracePeriodSeconds = 30;
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerImage;
                args = commonArgs ++ [
                  "--user=krxXVNVMM7.forge-n1"
                  "--pass=x"
                  "--user=krxXVNVMM7.forge-n1"
                  "--pass=x"
                  "--devices=1"
                  "--apiport=4069"
                  "--cclk=2350 --moff=1100 --pl=90"
                ];
                env = nvidiaEnv;
                ports = [
                  {
                    containerPort = 4069;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = 4069;
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  tcpSocket.port = 4069;
                  initialDelaySeconds = 60;
                  periodSeconds = 15;
                  failureThreshold = 10;
                };
                resources = {
                  requests = {
                    memory = "4Gi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "8Gi";
                    cpu = "1";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                }
                // nvidiaVolumeMounts;
              };
            };
            volumes = {
              _namedlist = true;
            }
            // nvidiaVolumes;
          };
        };
      };
    };

    mining.Deployment.gpu-miner-forge-amd-0 = {
      metadata.labels.app = "gpu-miner-forge-amd-0";
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector.matchLabels.app = "gpu-miner-forge-amd-0";
        strategy.type = "Recreate";
        template = {
          metadata.labels.app = "gpu-miner-forge-amd-0";
          spec = {
            nodeName = "forge";
            hostNetwork = true;
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            terminationGracePeriodSeconds = 30;
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerAmdImage;
                imagePullPolicy = "Never";
                args = commonArgs ++ [
                  "--user=krxXVNVMM7.forge-a0"
                  "--pass=x"
                  "--user=krxXVNVMM7.forge-a0"
                  "--pass=x"
                  "--devices=0"
                  "--apiport=4070"
                ];
                env = amdEnv;
                ports = [
                  {
                    containerPort = 4070;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = 4070;
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  tcpSocket.port = 4070;
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "512Mi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "2Gi";
                    cpu = "1";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                }
                // amdVolumeMounts;
              };
            };
            volumes = {
              _namedlist = true;
            }
            // amdVolumes;
          };
        };
      };
    };

    mining.Deployment.gpu-miner-forge-amd-1 = {
      metadata.labels.app = "gpu-miner-forge-amd-1";
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector.matchLabels.app = "gpu-miner-forge-amd-1";
        strategy.type = "Recreate";
        template = {
          metadata.labels.app = "gpu-miner-forge-amd-1";
          spec = {
            nodeName = "forge";
            hostNetwork = true;
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            terminationGracePeriodSeconds = 30;
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerAmdImage;
                imagePullPolicy = "Never";
                args = commonArgs ++ [
                  "--user=krxXVNVMM7.forge-a1"
                  "--pass=x"
                  "--user=krxXVNVMM7.forge-a1"
                  "--pass=x"
                  "--devices=1"
                  "--apiport=4071"
                ];
                env = amdEnv;
                ports = [
                  {
                    containerPort = 4071;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = 4071;
                  initialDelaySeconds = 30;
                  periodSeconds = 30;
                  failureThreshold = 3;
                };
                readinessProbe = {
                  tcpSocket.port = 4071;
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  failureThreshold = 3;
                };
                resources = {
                  requests = {
                    memory = "512Mi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "2Gi";
                    cpu = "1";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                }
                // amdVolumeMounts;
              };
            };
            volumes = {
              _namedlist = true;
            }
            // amdVolumes;
          };
        };
      };
    };

    mining.Deployment.gpu-miner-nexus = {
      metadata.labels = {
        app = "gpu-miner-nexus";
        host = "nexus";
        workload = "crypto-mining";
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector.matchLabels = {
          app = "gpu-miner-nexus";
          host = "nexus";
        };
        strategy.type = "Recreate";
        template = {
          metadata.labels = {
            app = "gpu-miner-nexus";
            host = "nexus";
            workload = "crypto-mining";
          };
          spec = {
            nodeName = "nexus";
            hostNetwork = true;
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
            terminationGracePeriodSeconds = 30;
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerImage;
                args = commonArgs ++ [
                  "--user=krxXVNVMM7.nexus-gpu"
                  "--pass=x"
                  "--user=krxXVNVMM7.nexus-gpu"
                  "--pass=x"
                  "--devices=0"
                  "--apiport=4068"
                ];
                env = nvidiaEnv;
                ports = [
                  {
                    containerPort = 4068;
                    name = "api";
                    protocol = "TCP";
                  }
                ];
                livenessProbe = {
                  tcpSocket.port = 4068;
                  initialDelaySeconds = 120;
                  periodSeconds = 60;
                  failureThreshold = 5;
                };
                readinessProbe = {
                  tcpSocket.port = 4068;
                  initialDelaySeconds = 60;
                  periodSeconds = 15;
                  failureThreshold = 10;
                };
                resources = {
                  requests = {
                    memory = "2Gi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "4Gi";
                    cpu = "1";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                }
                // nvidiaVolumeMounts;
              };
            };
            volumes = {
              _namedlist = true;
            }
            // nvidiaVolumes;
          };
        };
      };
    };

    mining.Deployment.gpu-miner-zephyr = {
      metadata = {
        labels = {
          app = "gpu-miner-zephyr";
          host = "zephyr";
          workload = "crypto-mining";
        };
      };
      spec = {
        replicas = 1;
        revisionHistoryLimit = 1;
        selector = {
          matchLabels = {
            app = "gpu-miner-zephyr";
            host = "zephyr";
          };
        };
        strategy.type = "Recreate";
        template = {
          metadata = {
            labels = {
              app = "gpu-miner-zephyr";
              host = "zephyr";
              workload = "crypto-mining";
            };
          };
          spec = {
            nodeName = "zephyr";
            hostNetwork = true;
            automountServiceAccountToken = false;
            serviceAccountName = "gpu-miner-sa";
            priorityClassName = "mining-low";
            tolerations = [
              {
                key = "workstation";
                operator = "Exists";
              }
              {
                key = "interactive";
                operator = "Exists";
              }
              {
                key = "node-role.kubernetes.io/control-plane";
                operator = "Exists";
                effect = "NoSchedule";
              }
            ];
            containers = {
              _namedlist = true;
              lolminer = {
                image = lolminerImage;
                imagePullPolicy = "IfNotPresent";
                args = [
                  "--algo=CR29"
                  "--pool=xtm-c29-us.kryptex.network:8040"
                  "--user=krxXVNVMM7.zephyr-gpu"
                  "--pass=x"
                  "--tls=1"
                  "--pool=xtm-c29-eu.kryptex.network:8040"
                  "--user=krxXVNVMM7.zephyr-gpu"
                  "--pass=x"
                  "--tls=1"
                  "--devices=1"
                  "--apiport=4068"
                ];
                env = {
                  _namedlist = true;
                  LD_LIBRARY_PATH = {
                    name = "LD_LIBRARY_PATH";
                    value = "/run/opengl-driver/lib:/usr/local/cuda-12.1/compat";
                  };
                };
                securityContext.privileged = true;
                volumeMounts = {
                  _namedlist = true;
                  dev = {
                    mountPath = "/dev";
                  };
                  nvidia-libs = {
                    mountPath = "/run/opengl-driver/lib";
                    readOnly = true;
                  };
                  nix-store = {
                    mountPath = "/nix/store";
                    readOnly = true;
                  };
                };
                resources = {
                  requests = {
                    memory = "4Gi";
                    cpu = "1";
                  };
                  limits = {
                    memory = "8Gi";
                    cpu = "1";
                  };
                };
              };
            };
            volumes = {
              _namedlist = true;
              dev = {
                hostPath.path = "/dev";
              };
              nvidia-libs = {
                hostPath.path = "/run/opengl-driver/lib";
              };
              nix-store = {
                hostPath.path = "/nix/store";
              };
            };
          };
        };
      };
    };
  };
}
