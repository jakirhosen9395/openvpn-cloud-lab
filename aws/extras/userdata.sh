#!/bin/bash
# =============================================================================
# EC2 DASHBOARD - user-data bootstrap script
# -----------------------------------------------------------------------------
# WHAT THIS DOES
#   AWS runs this script ONCE as root when the EC2 instance first boots
#   (this is called "user data"). It installs the Apache web server and
#   publishes a small web page (a "dashboard") on port 80 that shows live
#   information about the server: OS, EC2 details, network, IAM role,
#   CPU, memory and disk.
#
#   Open it in a browser at:   http://SERVER_IP/
#
# DESIGN GOALS
#   * Lowest cost / lowest internet use: installs ONLY Apache (and curl if it
#     is missing). No full system upgrade and no extra packages.
#   * Works on PUBLIC and PRIVATE instances. The dashboard reads data from the
#     local machine and from the EC2 metadata service at 169.254.169.254 -
#     a "link-local" address that works WITHOUT internet access.
#   * Beginner friendly: short functions, plain commands, lots of comments.
#     You can read every line, run every command by hand, and learn from it.
# =============================================================================

# Send everything this script prints (and any errors) into one log file.
# Read it later with:   cat /var/log/ec2-dashboard-userdata.log
exec > /var/log/ec2-dashboard-userdata.log 2>&1

# Stop the script immediately if any command fails, so problems are obvious.
set -e

echo "=== EC2 dashboard setup started: $(date) ==="

# -----------------------------------------------------------------------------
# Global variables. detect_os() fills these in. They are empty for now.
# -----------------------------------------------------------------------------
PKG=""                     # which package manager: "apt", "dnf", or "yum"
APACHE_SERVICE=""          # systemd service name: "apache2" or "httpd"
WEB_ROOT="/var/www/html"   # folder Apache serves web pages from

# =============================================================================
# detect_os: work out which Linux distribution we are running on.
# Different distros use different package managers and Apache service names.
# =============================================================================
detect_os() {
  echo "Detecting operating system..."

  # /etc/os-release describes the distro. Loading it gives us $PRETTY_NAME.
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Detected OS: ${PRETTY_NAME}"
  else
    echo "Detected OS: unknown"
  fi

  # Choose the package manager and Apache service name for this distro.
  if command -v apt-get >/dev/null 2>&1; then
    PKG="apt"                # Debian / Ubuntu
    APACHE_SERVICE="apache2"
  elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"                # Amazon Linux 2023 / Fedora / RHEL 8+
    APACHE_SERVICE="httpd"
  elif command -v yum >/dev/null 2>&1; then
    PKG="yum"                # Amazon Linux 2 / older RHEL
    APACHE_SERVICE="httpd"
  else
    echo "ERROR: no supported package manager (need apt, dnf, or yum)."
    exit 1
  fi

  echo "Package manager: $PKG | Apache service: $APACHE_SERVICE"
}

# =============================================================================
# install_apache: install the web server (and curl) - and nothing else.
# We only install a package if it is MISSING. That keeps cost and internet use
# low, and lets the script also work on a PRIVATE instance where Apache is
# already baked into the AMI and there is no internet to download packages.
# =============================================================================
install_apache() {
  echo "Installing Apache..."

  if [ "$PKG" = "apt" ]; then
    # On Debian/Ubuntu, do not ask interactive questions during installation.
    export DEBIAN_FRONTEND=noninteractive

    # Install curl only if it is not already present (most AMIs have it).
    if ! command -v curl >/dev/null 2>&1; then
      apt-get update -y          # refresh the list of available packages
      apt-get install -y curl    # curl reads the EC2 metadata service
    fi

    # Install Apache only if it is not already present.
    if ! command -v apache2 >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y apache2
    else
      echo "Apache already installed - skipping."
    fi

  else
    # Amazon Linux / RHEL / Fedora use dnf or yum (whichever is in $PKG).
    if ! command -v curl >/dev/null 2>&1; then
      "$PKG" install -y curl
    fi
    if ! command -v httpd >/dev/null 2>&1; then
      "$PKG" install -y httpd
    else
      echo "Apache already installed - skipping."
    fi
  fi
}

# =============================================================================
# configure_apache: tell Apache to run our shell-script dashboard on port 80.
# The dashboard is a small shell script (a "CGI" script). Apache runs it every
# time the page is opened, so the numbers shown are always fresh.
# =============================================================================
configure_apache() {
  echo "Configuring Apache..."

  # Create the web root folder if it does not already exist.
  mkdir -p "$WEB_ROOT"

  if [ "$PKG" = "apt" ]; then
    # Turn on the CGI module so Apache is allowed to run scripts.
    a2enmod cgid >/dev/null 2>&1 || true

    # Replace the default site config with our own: serve on port 80 and run
    # index.sh as the home page.
    cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:80>
    DocumentRoot $WEB_ROOT
    DirectoryIndex index.sh

    <Directory $WEB_ROOT>
        Options +ExecCGI
        AddHandler cgi-script .sh
        Require all granted
    </Directory>
</VirtualHost>
EOF

  else
    # On RHEL / Amazon Linux the CGI module is already enabled by default,
    # so we just drop in our own site configuration file.
    cat > /etc/httpd/conf.d/dashboard.conf <<EOF
<VirtualHost *:80>
    DocumentRoot "$WEB_ROOT"
    DirectoryIndex index.sh

    <Directory "$WEB_ROOT">
        Options +ExecCGI
        AddHandler cgi-script .sh
        Require all granted
    </Directory>
</VirtualHost>
EOF
  fi
}

# =============================================================================
# create_dashboard: write the dashboard program into the web root.
# This is a CGI shell script. When someone opens the page, Apache runs it and
# the script prints fresh HTML describing the server right now.
# =============================================================================
create_dashboard() {
  echo "Creating dashboard..."

  # Remove Apache's default welcome page so our dashboard is shown instead.
  rm -f "$WEB_ROOT/index.html"

  # Write the dashboard script. The quotes around 'DASHBOARD' mean the text is
  # saved EXACTLY as written - the $variables below are filled in later, at the
  # moment Apache runs the script (not now).
  cat > "$WEB_ROOT/index.sh" <<'DASHBOARD'
#!/bin/bash
# Apache runs this script. A CGI script must print an HTTP header, then a
# blank line, then the HTML page.

# --- 1. Send the HTTP header that says "this is an HTML page" ---
echo "Content-type: text/html; charset=UTF-8"
echo ""

# --- 2. Get a token for the EC2 metadata service (IMDSv2) ---
# The metadata service lives at 169.254.169.254. It is a link-local address,
# so it works even with no internet. Modern instances need a short token first.
TOKEN=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

# Small helper: read one metadata field. Example: get_meta instance-id
get_meta() {
  curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"
}

# --- 3. Collect EC2 information from the metadata service ---
INSTANCE_ID=$(get_meta instance-id)
INSTANCE_TYPE=$(get_meta instance-type)
AMI_ID=$(get_meta ami-id)
AVAILABILITY_ZONE=$(get_meta placement/availability-zone)
REGION=$(get_meta placement/region)
PRIVATE_IP=$(get_meta local-ipv4)
PUBLIC_IP=$(get_meta public-ipv4)
IAM_ROLE=$(get_meta iam/security-credentials/)

# --- 4. Replace empty values with friendly text ---
# A private-subnet instance has no public IP, so show a clear message.
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="Private Subnet Instance"
fi
if [ -z "$IAM_ROLE" ]; then
  IAM_ROLE="No IAM role attached"
fi

# Is the metadata service reachable? If we got an instance id, yes.
if [ -n "$INSTANCE_ID" ]; then
  META_STATUS="Available"
else
  META_STATUS="Unavailable"
  INSTANCE_ID="Unavailable"
  INSTANCE_TYPE="Unavailable"
  AMI_ID="Unavailable"
  AVAILABILITY_ZONE="Unavailable"
  REGION="Unavailable"
fi

# --- 5. Collect local Linux information with simple commands ---
HOSTNAME=$(hostname)
OS=$(. /etc/os-release; echo "$PRETTY_NAME")
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p)
CURRENT_TIME=$(date)

# CPU load: the first three numbers in /proc/loadavg are the 1, 5 and 15
# minute load averages.
CPU_LOAD=$(cut -d ' ' -f1-3 /proc/loadavg)

# Memory: "free -h" prints human-readable sizes; show used / total.
MEMORY=$(free -h | awk '/Mem:/ {print $3 " / " $2}')

# Disk: "df -h /" shows the root disk; show used / total and percent.
DISK=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

# --- 6. Print the HTML dashboard page ---
cat <<HTML
<!DOCTYPE html>
<html>
<head>
<title>$OS Dashboard</title>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="5">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box}
body{margin:0;padding:22px;font-family:Arial,Helvetica,sans-serif;color:#0f172a;background:linear-gradient(135deg,#0f172a,#312e81 55%,#0369a1);min-height:100vh}
.wrap{max-width:1050px;margin:auto}
.hero{text-align:center;color:white;margin-bottom:22px}
.hero h1{font-size:38px;margin:10px 0}
.hero p{color:#dbeafe;margin:6px 0 16px}
.badge{display:inline-block;margin:4px;padding:8px 13px;border-radius:999px;background:rgba(255,255,255,.14);color:#e0f2fe;border:1px solid rgba(255,255,255,.22)}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.card{background:#fff;border-radius:20px;padding:22px;box-shadow:0 16px 38px rgba(0,0,0,.28);border:1px solid #e0f2fe}
.full{grid-column:1/-1}
h2{margin:0 0 14px;color:#1e293b;font-size:21px;border-bottom:2px solid #e2e8f0;padding-bottom:10px}
ul{list-style:none;margin:0;padding:0}
li{display:flex;justify-content:space-between;gap:14px;padding:10px 0;border-bottom:1px dashed #cbd5e1;line-height:1.45}
li:last-child{border:0}
.label{font-weight:700;color:#475569}
.value{font-weight:700;text-align:right;word-break:break-word}
.pill{display:inline-block;padding:5px 11px;border-radius:999px;font-weight:800}
.blue{background:#dbeafe;color:#1d4ed8}
.green{background:#dcfce7;color:#166534}
.purple{background:#ede9fe;color:#6d28d9}
.orange{background:#ffedd5;color:#c2410c}
.usage{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.box{background:linear-gradient(135deg,#f8fafc,#dbeafe);border:1px solid #bfdbfe;border-radius:16px;padding:17px}
.box b{display:block;color:#475569;margin-bottom:7px}
.box span{font-size:17px;font-weight:800}
.footer{text-align:center;color:#dbeafe;margin-top:22px}
@media(max-width:760px){body{padding:12px}.grid,.usage{grid-template-columns:1fr}.hero h1{font-size:30px}li{display:block}.value{text-align:left;display:block;margin-top:4px}}
</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <h1>🖥️ $OS Dashboard</h1>
    <p>Live AWS and Linux server information</p>
    <span class="badge">🌐 Apache Dashboard Port 80</span>
    <span class="badge">🔄 Refreshes every 5 seconds</span>
    <span class="badge">📡 Metadata: $META_STATUS</span>
  </div>

  <div class="grid">
    <div class="card">
      <h2>☁️ AWS Information</h2>
      <ul>
        <li><span class="label">Instance ID</span><span class="value">$INSTANCE_ID</span></li>
        <li><span class="label">Instance Type</span><span class="value"><span class="pill blue">$INSTANCE_TYPE</span></span></li>
        <li><span class="label">AMI ID</span><span class="value">$AMI_ID</span></li>
        <li><span class="label">Region</span><span class="value"><span class="pill green">$REGION</span></span></li>
        <li><span class="label">Availability Zone</span><span class="value">$AVAILABILITY_ZONE</span></li>
        <li><span class="label">IAM Role</span><span class="value">$IAM_ROLE</span></li>
      </ul>
    </div>

    <div class="card">
      <h2>🌐 Network Information</h2>
      <ul>
        <li><span class="label">Private IP</span><span class="value">$PRIVATE_IP</span></li>
        <li><span class="label">Public IP</span><span class="value"><span class="pill orange">$PUBLIC_IP</span></span></li>
        <li><span class="label">Hostname</span><span class="value">$HOSTNAME</span></li>
      </ul>
    </div>

    <div class="card">
      <h2>🖥️ System Information</h2>
      <ul>
        <li><span class="label">Operating System</span><span class="value">$OS</span></li>
        <li><span class="label">Kernel</span><span class="value">$KERNEL</span></li>
        <li><span class="label">Architecture</span><span class="value"><span class="pill purple">$ARCH</span></span></li>
        <li><span class="label">Uptime</span><span class="value">$UPTIME</span></li>
        <li><span class="label">Current Time</span><span class="value">$CURRENT_TIME</span></li>
      </ul>
    </div>

    <div class="card">
      <h2>📡 Connectivity</h2>
      <ul>
        <li><span class="label">Metadata Service</span><span class="value"><span class="pill green">$META_STATUS</span></span></li>
      </ul>
    </div>

    <div class="card full">
      <h2>📊 Resource Usage</h2>
      <div class="usage">
        <div class="box"><b>⚙️ CPU Load (1/5/15 min)</b><span>$CPU_LOAD</span></div>
        <div class="box"><b>🧠 Memory</b><span>$MEMORY</span></div>
        <div class="box"><b>💾 Disk</b><span>$DISK</span></div>
      </div>
    </div>
  </div>

  <div class="footer">⚡ Powered by Apache CGI on Amazon EC2</div>
</div>
</body>
</html>
HTML
DASHBOARD

  # Make the dashboard script executable so Apache is allowed to run it.
  chmod 755 "$WEB_ROOT/index.sh"

  # On SELinux systems (Amazon Linux / RHEL), give Apache permission to run the
  # script. This block does nothing on Ubuntu (which does not use SELinux).
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
    chcon -t httpd_sys_script_exec_t "$WEB_ROOT/index.sh" || true
    setsebool -P httpd_enable_cgi 1 || true
  fi
}

# =============================================================================
# start_apache: start the web server and make sure it is really running.
# =============================================================================
start_apache() {
  echo "Starting Apache..."

  systemctl enable "$APACHE_SERVICE"    # start automatically on every boot
  systemctl restart "$APACHE_SERVICE"   # load our new config right now

  # Confirm Apache is actually running. If not, show why and stop.
  if systemctl is-active --quiet "$APACHE_SERVICE"; then
    echo "Apache is running."
  else
    echo "ERROR: Apache did not start. Recent status:"
    systemctl status "$APACHE_SERVICE" || true
    exit 1
  fi
}

# =============================================================================
# print_result: print a short summary and the dashboard URL into the log.
# =============================================================================
print_result() {
  # Read the public IP (if any) just to print a friendly URL. "|| true" keeps
  # the script from stopping if the metadata call fails (e.g. private subnet).
  TOKEN=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
  PUBLIC_IP=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/public-ipv4" || true)
  PRIVATE_IP=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/local-ipv4" || true)

  echo "=================================================="
  echo "EC2 dashboard setup finished: $(date)"
  if [ -n "$PUBLIC_IP" ]; then
    echo "Open the dashboard at:  http://$PUBLIC_IP/"
  else
    echo "This looks like a PRIVATE instance (no public IP)."
    echo "Open it from inside the VPC at:  http://$PRIVATE_IP/"
  fi
  echo ""
  echo "Security Group: allow inbound TCP 80 from your IP."
  echo "Log file:       /var/log/ec2-dashboard-userdata.log"
  echo "=================================================="
}

# =============================================================================
# MAIN: run the steps in order. Read this list to understand the whole script.
# =============================================================================
detect_os         # 1. which Linux is this?
install_apache    # 2. install the web server (only if missing)
configure_apache  # 3. point Apache at our dashboard on port 80
create_dashboard  # 4. write the dashboard CGI script
start_apache      # 5. start Apache and verify it is up
print_result      # 6. print the dashboard URL and a summary

echo "=== EC2 dashboard setup completed: $(date) ==="
