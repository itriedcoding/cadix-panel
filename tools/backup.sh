#!/bin/bash
BACKUP_DIR="/opt/cadix-panel/data"
FILE="panel.backup.$(date +%Y%m%d_%H%M%S).db"
cp "$BACKUP_DIR/panel.db" "$BACKUP_DIR/$FILE"
echo "Backup: $FILE ($(du -h "$BACKUP_DIR/$FILE" | awk '{print $1}'))"
find "$BACKUP_DIR" -name "panel.backup.*.db" -mtime +7 -delete
