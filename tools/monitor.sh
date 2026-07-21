#!/bin/bash
echo "=== Cadix Monitor ==="
echo "CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')%"
echo "RAM: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo "Disk: $(df -h / | awk 'NR==2 {print $3 "/" $2}')"
echo "Uptime: $(uptime -p | sed 's/up //')"
echo "Load: $(cat /proc/loadavg | awk '{print $1", "$2", "$3}')"
echo "Processes: $(ps aux | wc -l)"
echo "Open ports: $(ss -tln | wc -l)"
