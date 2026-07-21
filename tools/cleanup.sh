#!/bin/bash
echo "Cleaning..."
apt-get autoremove -y -qq
apt-get autoclean -qq
journalctl --vacuum-time=7d >/dev/null 2>&1
find /opt/cadix-panel/logs -name "*.log" -mtime +30 -delete
echo "Done"
