Third-party installers go in this folder before Install-StorSafeMonitoring.ps1 (Windows) or linux/install.sh (Linux) is run.
Easiest: run ..\Get-StorSafeInstallers.ps1 (downloads the versions below; -*Version to pick others, -Proxy if needed).
On Linux: run ../linux/get-installers.sh (downloads the four tarballs below; --*-version to pick others, --print-urls lists the URLs for a host with no internet access).
Or download by hand (any recent version; the installer picks the newest file matching each pattern):

  windows_exporter-<ver>-amd64.msi        https://github.com/prometheus-community/windows_exporter/releases
  prometheus-<ver>.windows-amd64.zip      https://prometheus.io/download/#prometheus
  grafana-<ver>.windows-amd64.msi         https://grafana.com/grafana/download?platform=windows  (OSS or Enterprise)

On Linux (x86_64), the same way:

  node_exporter-<ver>.linux-amd64.tar.gz  https://github.com/prometheus/node_exporter/releases
  prometheus-<ver>.linux-amd64.tar.gz     https://prometheus.io/download/#prometheus
  grafana-<ver>.linux-amd64.tar.gz        https://grafana.com/grafana/download?platform=linux
  powershell-<ver>-linux-x64.tar.gz       https://github.com/PowerShell/PowerShell/releases  (7.6 LTS line; only used when pwsh is not installed)

Tested with: windows_exporter 0.31.8, Prometheus 3.15.0, Grafana 12.0.2.
Tested with (Linux): node_exporter 1.12.1, Prometheus 3.15.0, Grafana 12.0.2, PowerShell 7.6.6.
Skip any component the server already has with -SkipExporter / -SkipPrometheus / -SkipGrafana (Windows) or --collector-only (Linux, no Prometheus or Grafana).
