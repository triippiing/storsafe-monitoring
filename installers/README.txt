Third-party installers go in this folder before Install-StorSafeMonitoring.ps1 is run.
Easiest: run ..\Get-StorSafeInstallers.ps1 (downloads the versions below; -*Version to pick others, -Proxy if needed).
Or download by hand (any recent version; the installer picks the newest file matching each pattern):

  windows_exporter-<ver>-amd64.msi        https://github.com/prometheus-community/windows_exporter/releases
  prometheus-<ver>.windows-amd64.zip      https://prometheus.io/download/#prometheus
  grafana-<ver>.windows-amd64.msi         https://grafana.com/grafana/download?platform=windows  (OSS or Enterprise)

Tested with: windows_exporter 0.31.8, Prometheus 3.15.0, Grafana 12.0.2.
Skip any component the server already has with -SkipExporter / -SkipPrometheus / -SkipGrafana.
