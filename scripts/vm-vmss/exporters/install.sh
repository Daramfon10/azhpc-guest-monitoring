#!/bin/bash
set -e

# Configuration variables
NODE_EXPORTER_VERSION=1.9.1
DCGM_EXPORTER_VERSION="4.2.3-4.1.3-ubuntu22.04"
NODE_EXPORTER_PORT=9100
DCGM_EXPORTER_PORT=9400
CUSTOM_COUNTERS_URL=""  # Optional: URL to fetch custom counters CSV

# Detect architecture for Node Exporter
if [[ $(uname -m) == "aarch64" ]]; then
    NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-arm64.tar.gz"
else
    NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
fi

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/monitoring_exporters_install.log
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log "ERROR: This script must be run as root"
   exit 1
fi

# Check if NVIDIA GPU is present (for DCGM Exporter)
check_nvidia_gpu() {
    log "Checking for NVIDIA GPU..."
    
    if ! command -v nvidia-smi &> /dev/null; then
        log "WARNING: nvidia-smi not found. DCGM Exporter will be skipped."
        return 1
    fi
    
    if ! nvidia-smi -L > /dev/null 2>&1; then
        log "WARNING: nvidia-smi command failed. DCGM Exporter will be skipped."
        return 1
    fi
    
    local gpu_count=$(nvidia-smi -L | wc -l)
    log "Found $gpu_count NVIDIA GPU(s)"
    nvidia-smi -L | while read line; do
        log "  $line"
    done
    return 0
}

# Install required packages
install_dependencies() {
    log "Installing dependencies..."
    
    # Detect package manager and install required packages
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y wget curl
    elif command -v yum &> /dev/null; then
        yum update -y
        yum install -y wget curl
    elif command -v dnf &> /dev/null; then
        dnf update -y
        dnf install -y wget curl
    else
        log "ERROR: Unsupported package manager"
        exit 1
    fi
}

# Install Docker (for DCGM Exporter)
install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker already installed: $(docker --version)"
        return 0
    fi
    
    log "Installing Docker..."
    
    # Detect package manager and install Docker
    if command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        
        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Add repository
        echo \
          "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v yum &> /dev/null; then
        # CentOS/RHEL
        yum update -y
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    elif command -v dnf &> /dev/null; then
        # Fedora
        dnf update -y
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
    else
        log "ERROR: Unsupported package manager for Docker installation"
        exit 1
    fi
    
    # Start and enable Docker
    systemctl start docker
    systemctl enable docker
    
    log "Docker installed successfully: $(docker --version)"
}

# Install Node Exporter
install_node_exporter() {
    log "Installing Node Exporter version ${NODE_EXPORTER_VERSION}..."
    
    # Create installation directory
    if [ ! -d /opt/node_exporter ]; then
        mkdir -p /opt/node_exporter
        cd /opt
        
        # Download Node Exporter
        log "Downloading ${NODE_EXPORTER_PACKAGE}..."
        wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}"
        
        # Extract
        log "Extracting Node Exporter..."
        tar xf "${NODE_EXPORTER_PACKAGE}" -C node_exporter --strip-components=1
        
        # Set ownership
        chown -R root:root node_exporter
        chmod +x node_exporter/node_exporter
        
        # Cleanup
        rm -f "${NODE_EXPORTER_PACKAGE}"
        log "Node Exporter binary installed to /opt/node_exporter/"
    else
        log "Node Exporter directory already exists, skipping download"
    fi
}

# Create Node Exporter user and group
create_node_exporter_user() {
    log "Creating node_exporter user and group..."
    
    # Create group
    if ! getent group node_exporter >/dev/null; then
        groupadd -r node_exporter
        log "Created node_exporter group"
    fi
    
    # Create user
    if ! id -u node_exporter >/dev/null 2>&1; then
        useradd -r -g node_exporter -s /sbin/nologin -d /opt/node_exporter node_exporter
        log "Created node_exporter user"
    fi
}

# Create Node Exporter systemd service
create_node_exporter_service() {
    log "Creating Node Exporter systemd service..."
    
    # Create systemd service with custom collector options
    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
Documentation=https://prometheus.io/docs/guides/node-exporter/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
EnvironmentFile=/etc/sysconfig/node_exporter
ExecStart=/opt/node_exporter/node_exporter --web.listen-address=:9100 $OPTIONS
Restart=always
RestartSec=15
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

    # Create environment file with custom collector options
    mkdir -p /etc/sysconfig
    cat > /etc/sysconfig/node_exporter << 'EOF'
# Node Exporter collector options (matching CycleCloud configuration)
OPTIONS="--collector.mountstats \
--collector.cpu.info \
--no-collector.arp \
--no-collector.bcache \
--no-collector.bonding \
--no-collector.btrfs \
--no-collector.conntrack \
--no-collector.cpufreq \
--no-collector.dmi \
--no-collector.edac \
--no-collector.entropy \
--no-collector.fibrechannel \
--no-collector.filefd \
--no-collector.hwmon \
--no-collector.ipvs \
--no-collector.mdadm \
--no-collector.netclass \
--no-collector.netstat \
--no-collector.nfs \
--no-collector.nfsd \
--no-collector.nvme \
--no-collector.os \
--no-collector.powersupplyclass \
--no-collector.pressure \
--no-collector.rapl \
--no-collector.schedstat \
--no-collector.selinux \
--no-collector.sockstat \
--no-collector.softnet \
--no-collector.tapestats \
--no-collector.textfile \
--no-collector.thermal_zone \
--no-collector.timex \
--no-collector.udp_queues \
--no-collector.watchdog \
--no-collector.xfs \
--no-collector.zfs"
EOF

    log "Node Exporter systemd service created"
}

# Start Node Exporter service
start_node_exporter() {
    log "Starting Node Exporter service..."
    
    systemctl daemon-reload
    systemctl enable node_exporter
    systemctl start node_exporter
    
    # Wait a moment and check status
    sleep 3
    if systemctl is-active --quiet node_exporter; then
        log "Node Exporter service started successfully"
        
        # Test the endpoint
        if curl -s http://localhost:${NODE_EXPORTER_PORT}/metrics > /dev/null; then
            log "Node Exporter is responding on port ${NODE_EXPORTER_PORT}"
        else
            log "WARNING: Node Exporter service is running but not responding on port ${NODE_EXPORTER_PORT}"
        fi
    else
        log "ERROR: Node Exporter service failed to start"
        systemctl status node_exporter
        exit 1
    fi
}

# Create DCGM custom counters file
create_dcgm_custom_counters() {
    log "Creating DCGM custom counters configuration..."
    
    mkdir -p /opt/dcgm-exporter
    
    if [ -n "$CUSTOM_COUNTERS_URL" ]; then
        log "Downloading custom counters from: $CUSTOM_COUNTERS_URL"
        curl -fsSL "$CUSTOM_COUNTERS_URL" -o /opt/dcgm-exporter/custom-counters.csv
    else
        log "Creating custom counters file with comprehensive GPU metrics"
        cat > /opt/dcgm-exporter/custom-counters.csv << 'EOF'
# Format
# If line starts with a '#' it is considered a comment
# DCGM FIELD, Prometheus metric type, help message
# Clocks
DCGM_FI_DEV_SM_CLOCK,  gauge, SM clock frequency (in MHz).
DCGM_FI_DEV_MEM_CLOCK, gauge, Memory clock frequency (in MHz).
DCGM_FI_DEV_APP_MEM_CLOCK,  gauge, Ratio of time the graphics engine is active.
DCGM_FI_DEV_CLOCKS_EVENT_REASONS, gauge, Current clock throttle reasons.
# Temperature
DCGM_FI_DEV_MEMORY_TEMP, gauge, Memory temperature (in C).
DCGM_FI_DEV_GPU_TEMP,    gauge, GPU temperature (in C).
DCGM_FI_DEV_GPU_MAX_OP_TEMP, gauge, Maximum operating temperature for this GPU.
# Power & Energy
DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
DCGM_FI_DEV_POWER_MGMT_LIMIT, gauge, Current Power limit for the device (in W)
DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION, counter, Total energy consumption since boot (in mJ).
# PCIE
DCGM_FI_PROF_PCIE_TX_BYTES,  counter, Total number of bytes transmitted through PCIe TX via NVML.
DCGM_FI_PROF_PCIE_RX_BYTES,  counter, Total number of bytes received through PCIe RX via NVML.
DCGM_FI_DEV_PCIE_REPLAY_COUNTER, counter, Total number of PCIe retries.
# Utilization (the sample period varies depending on the product)
DCGM_FI_DEV_GPU_UTIL,      gauge, GPU utilization (in %).
DCGM_FI_DEV_MEM_COPY_UTIL, gauge, Memory utilization (in %).
# Errors and violations
DCGM_FI_DEV_XID_ERRORS,              gauge,   Value of the last XID error encountered.
DCGM_FI_DEV_POWER_VIOLATION,       counter, Throttling duration due to power constraints (in us).
DCGM_FI_DEV_THERMAL_VIOLATION,     counter, Throttling duration due to thermal constraints (in us).
# Memory usage
#DCGM_FI_DEV_FB_FREE, gauge, Framebuffer memory free (in MiB).
#DCGM_FI_DEV_FB_USED, gauge, Framebuffer memory used (in MiB).
# ECC
DCGM_FI_DEV_ECC_SBE_VOL_TOTAL, counter, Total number of single-bit volatile ECC errors.
DCGM_FI_DEV_ECC_DBE_VOL_TOTAL, counter, Total number of double-bit volatile ECC errors.
DCGM_FI_DEV_ECC_SBE_AGG_TOTAL, counter, Total number of single-bit persistent ECC errors.
DCGM_FI_DEV_ECC_DBE_AGG_TOTAL, counter, Total number of double-bit persistent ECC errors.
# NVLink
DCGM_FI_DEV_NVLINK_COUNT_LINK_RECOVERY_FAILED_EVENTS, counter, Number of times link went from Up to recovery failed and link down.
DCGM_FI_DEV_NVLINK_COUNT_LOCAL_LINK_INTEGRITY_ERRORS, counter, Total number of times that the count of local errors.
DCGM_FI_DEV_NVLINK_COUNT_RX_ERRORS, counter, Total number of packets with errors Rx on a link.
DCGM_FI_DEV_NVLINK_COUNT_TX_DISCARDS, counter, Total number of tx error packets that were discarded.
DCGM_FI_PROF_NVLINK_TX_BYTES, counter, Nvlink Port Raw bandwidth (TX)
DCGM_FI_PROF_NVLINK_RX_BYTES, counter, Nvlink Port Raw bandwidth (RX)
# Datacenter Profiling (DCP) metrics
# NOTE: supported on Nvidia datacenter Volta GPUs and newer
DCGM_FI_PROF_SM_ACTIVE,          gauge, The ratio of cycles an SM has at least 1 warp assigned.
DCGM_FI_PROF_SM_OCCUPANCY,       gauge, The ratio of number of warps resident on an SM.
DCGM_FI_PROF_PIPE_TENSOR_ACTIVE, gauge, Ratio of cycles the tensor (HMMA) pipe is active.
DCGM_FI_PROF_DRAM_ACTIVE,        gauge, Ratio of cycles the device memory interface is active sending or receiving data.
DCGM_FI_PROF_PIPE_FP64_ACTIVE,   gauge, Ratio of cycles the fp64 pipes are active.
DCGM_FI_PROF_PIPE_FP32_ACTIVE,   gauge, Ratio of cycles the fp32 pipes are active.
DCGM_FI_PROF_PIPE_FP16_ACTIVE,   gauge, Ratio of cycles the fp16 pipes are active.
EOF
    fi
    
    log "DCGM custom counters file created at /opt/dcgm-exporter/custom-counters.csv"
}

# Install and run DCGM Exporter
install_dcgm_exporter() {
    log "Installing and starting DCGM Exporter..."
    
    # Stop any existing container
    if docker ps -a --format 'table {{.Names}}' | grep -q "dcgm-exporter"; then
        log "Stopping existing DCGM Exporter container..."
        docker stop dcgm-exporter 2>/dev/null || true
        docker rm dcgm-exporter 2>/dev/null || true
    fi
    
    # Run DCGM Exporter container (will pull image if not present)
    log "Starting DCGM Exporter container..."
    docker run \
        --name dcgm-exporter \
        -v /opt/dcgm-exporter/custom-counters.csv:/etc/dcgm-exporter/custom-counters.csv:ro \
        -d --gpus all --cap-add SYS_ADMIN --rm \
        -p ${DCGM_EXPORTER_PORT}:${DCGM_EXPORTER_PORT} \
        nvcr.io/nvidia/k8s/dcgm-exporter:${DCGM_EXPORTER_VERSION} \
        -f /etc/dcgm-exporter/custom-counters.csv
    
    # Wait for container to start
    sleep 5
    
    # Check if container is running
    if docker ps --format 'table {{.Names}}' | grep -q "dcgm-exporter"; then
        log "DCGM Exporter container started successfully"
        
        # Test the endpoint
        if curl -s http://localhost:${DCGM_EXPORTER_PORT}/metrics > /dev/null; then
            log "DCGM Exporter is responding on port ${DCGM_EXPORTER_PORT}"
            
            # Show sample metrics
            local metric_count=$(curl -s http://localhost:${DCGM_EXPORTER_PORT}/metrics | grep -c "^DCGM_FI" || echo "0")
            log "Exposing $metric_count DCGM metrics"
        else
            log "WARNING: DCGM Exporter container is running but not responding on port ${DCGM_EXPORTER_PORT}"
        fi
    else
        log "ERROR: DCGM Exporter container failed to start"
        docker logs dcgm-exporter 2>/dev/null || true
        exit 1
    fi
}

# Main execution
main() {
    log "Starting monitoring exporters installation..."
    log "System: $(uname -a)"
    log "Architecture: $(uname -m)"
    log "Node Exporter Version: ${NODE_EXPORTER_VERSION}"
    log "DCGM Exporter Version: ${DCGM_EXPORTER_VERSION}"
    
    # Install dependencies
    install_dependencies
    
    # Always install Node Exporter
    log "=== Installing Node Exporter ==="
    install_node_exporter
    create_node_exporter_user
    create_node_exporter_service
    start_node_exporter
    
    # Install DCGM Exporter only if NVIDIA GPU is present
    if check_nvidia_gpu; then
        log "=== Installing DCGM Exporter ==="
        install_docker
        create_dcgm_custom_counters
        install_dcgm_exporter
        
        log "Both Node Exporter and DCGM Exporter installation completed successfully!"
        log "Node Exporter metrics: http://$(hostname -I | awk '{print $1}'):${NODE_EXPORTER_PORT}/metrics"
        log "DCGM Exporter metrics: http://$(hostname -I | awk '{print $1}'):${DCGM_EXPORTER_PORT}/metrics"
    else
        log "Node Exporter installation completed successfully!"
        log "DCGM Exporter skipped (no NVIDIA GPU detected)"
        log "Node Exporter metrics: http://$(hostname -I | awk '{print $1}'):${NODE_EXPORTER_PORT}/metrics"
    fi
    
    log "Installation summary:"
    log "  Node Exporter: $(systemctl is-active node_exporter)"
    if check_nvidia_gpu > /dev/null 2>&1; then
        log "  DCGM Exporter: $(docker ps --filter name=dcgm-exporter --format '{{.Status}}' | head -1)"
    fi
}

# Run main function
main "$@"