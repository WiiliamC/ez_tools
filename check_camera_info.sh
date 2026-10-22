IDX=$1

echo "===================== camera idx: $IDX ====================="
echo "===================== camera info ====================="

v4l2-ctl --device=/dev/video$IDX --list-formats-ext
