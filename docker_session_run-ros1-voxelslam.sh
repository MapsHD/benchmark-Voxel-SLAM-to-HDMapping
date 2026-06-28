#!/bin/bash
# Run Voxel-SLAM on a rosbag (ROS 1 .bag or ROS 2 bag directory),
# record output topics, then convert the recorded bag to an HDMapping session.
#
# Voxel-SLAM publishes its per-scan world cloud on /map_scan and broadcasts its
# 6-DoF pose on /tf (camera_init -> aft_mapped). We record both, then the
# converter rebuilds the trajectory from /tf.

IMAGE_NAME='voxelslam_noetic'
TMUX_SESSION='ros1_Voxel-SLAM'

DATASET_CONTAINER_PATH='/ros_ws/dataset/input.bag'
CONVERTED_BAG_CONTAINER='/tmp/dataset_ros1.bag'
BAG_OUTPUT_CONTAINER='/ros_ws/recordings'

RECORDED_BAG_NAME="recorded-Voxel-SLAM.bag"
HDMAPPING_OUT_NAME="output_hdmapping"

# Recorded topics (used by the converter).
CLOUD_TOPIC="${CLOUD_TOPIC:-/map_scan}"
TF_CHILD_FRAME="${TF_CHILD_FRAME:-aft_mapped}"

# Sensor selection: which Voxel-SLAM launch file to use.
# avia | avia_fly | mid360 | hesai | ouster | velodyne
SENSOR="${SENSOR:-avia}"

usage() {
  echo "Usage:"
  echo "  $0 <input.bag-or-ros2bag-dir> <output_dir>"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  SENSOR        - Voxel-SLAM launch profile: avia|avia_fly|mid360|hesai|ouster|velodyne (default: avia)"
  echo "  LIDAR_TOPIC   - LiDAR topic name inside the bag (default: the profile's config topic)"
  echo "  IMU_TOPIC     - IMU topic name inside the bag   (default: the profile's config topic)"
  echo "  CLOUD_TOPIC   - Voxel-SLAM per-scan cloud topic (default: /map_scan)"
  exit 1
}

echo "=== Voxel-SLAM rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -e "$DATASET_HOST_PATH" ]]; then
  echo "Error: input does not exist: $DATASET_HOST_PATH"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# Determine launch file and the LiDAR/IMU topics declared in that profile's
# config (so a bag using different names can be remapped on rosbag play).
case "$SENSOR" in
  avia)     LAUNCH_FILE="vxlm_avia.launch";     CFG_LIDAR="/livox/lidar";          CFG_IMU="/livox/imu" ;;
  avia_fly) LAUNCH_FILE="vxlm_avia_fly.launch"; CFG_LIDAR="/livox/lidar";          CFG_IMU="/livox/imu" ;;
  mid360)   LAUNCH_FILE="vxlm_mid360.launch";   CFG_LIDAR="/livox/lidar";          CFG_IMU="/livox/imu" ;;
  hesai)    LAUNCH_FILE="vxlm_hesai.launch";    CFG_LIDAR="/hesai/pandar";         CFG_IMU="/alphasense/imu" ;;
  ouster)   LAUNCH_FILE="vxlm_ouster.launch";   CFG_LIDAR="/os1_cloud_node/points"; CFG_IMU="/os1_cloud_node/imu" ;;
  velodyne) LAUNCH_FILE="vxlm_velodyne.launch"; CFG_LIDAR="/velodyne_points";      CFG_IMU="/imu/data" ;;
  *)
    echo "Error: unknown SENSOR=$SENSOR (use avia|avia_fly|mid360|hesai|ouster|velodyne)"
    exit 1
    ;;
esac

# Bag-side topic names (default to the config topics → no remap needed)
LIDAR_TOPIC="${LIDAR_TOPIC:-$CFG_LIDAR}"
IMU_TOPIC="${IMU_TOPIC:-$CFG_IMU}"

echo "Input           : $DATASET_HOST_PATH"
echo "Output dir      : $BAG_OUTPUT_HOST"
echo "Sensor profile  : $SENSOR  ($LAUNCH_FILE)"
echo "LiDAR topic     : $LIDAR_TOPIC  (config expects $CFG_LIDAR)"
echo "IMU topic       : $IMU_TOPIC  (config expects $CFG_IMU)"
echo "Cloud topic     : $CLOUD_TOPIC"

if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

xhost +local:docker >/dev/null

# ── Phase 1: run Voxel-SLAM + record output topics ───────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e SENSOR="$SENSOR" \
  -e LAUNCH_FILE="$LAUNCH_FILE" \
  -e CFG_LIDAR="$CFG_LIDAR" \
  -e CFG_IMU="$CFG_IMU" \
  -e LIDAR_TOPIC="$LIDAR_TOPIC" \
  -e IMU_TOPIC="$IMU_TOPIC" \
  -e CLOUD_TOPIC="$CLOUD_TOPIC" \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash

    # ── If input is a ROS 2 bag directory, convert to a ROS 1 bag ──────────
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Converting ROS 2 bag to ROS 1 bag format..."
      rm -f '"$CONVERTED_BAG_CONTAINER"'
      rosbags-convert '"$DATASET_CONTAINER_PATH"' --dst '"$CONVERTED_BAG_CONTAINER"' || {
        echo "[convert] ERROR: rosbags-convert failed"; exit 1; }
      ROS1_BAG="'"$CONVERTED_BAG_CONTAINER"'"
    else
      ROS1_BAG="'"$DATASET_CONTAINER_PATH"'"
    fi

    export ROS1_BAG
    echo "[convert] ROS 1 bag ready at: $ROS1_BAG"
    ls -la $ROS1_BAG

    # Topic remap arguments for rosbag play, if the bag uses non-config names
    REMAP_ARGS=""
    if [[ "$LIDAR_TOPIC" != "$CFG_LIDAR" ]]; then
      REMAP_ARGS="$REMAP_ARGS $LIDAR_TOPIC:=$CFG_LIDAR"
    fi
    if [[ "$IMU_TOPIC" != "$CFG_IMU" ]]; then
      REMAP_ARGS="$REMAP_ARGS $IMU_TOPIC:=$CFG_IMU"
    fi
    export REMAP_ARGS
    echo "[play] rosbag remap args: $REMAP_ARGS"

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: roscore ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[roscore] starting..."
roscore
'\'' C-m

    # ---------- PANE 1: Voxel-SLAM (+ RViz) ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 4
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
rosparam set /use_sim_time true
echo "[voxel_slam] launching '"$LAUNCH_FILE"' ..."
roslaunch voxel_slam '"$LAUNCH_FILE"'
'\'' C-m

    # ---------- PANE 2: rosbag record ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 6
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
rm -f '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
rosbag record '"$CLOUD_TOPIC"' /tf -O '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 3: rosbag play ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 10
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[play] start"
rosbag play --clock $ROS1_BAG $REMAP_ARGS
echo "[play] done"
tmux wait-for -S BAG_DONE
'\'' C-m

    # ---------- PANE 4: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 12
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "=== ROS 1 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
rostopic list
echo ""
echo "--- Checking input LiDAR: '"$CFG_LIDAR"' ---"
timeout 5 rostopic hz '"$CFG_LIDAR"' 2>&1 &
echo ""
echo "--- Checking input IMU: '"$CFG_IMU"' ---"
timeout 5 rostopic hz '"$CFG_IMU"' 2>&1 &
echo ""
echo "--- Checking Voxel-SLAM output: '"$CLOUD_TOPIC"' ---"
timeout 5 rostopic hz '"$CLOUD_TOPIC"' 2>&1 &
echo ""
echo "--- Checking Voxel-SLAM TF (camera_init -> '"$TF_CHILD_FRAME"') ---"
timeout 5 rostopic hz /tf 2>&1 &
wait
echo ""
echo "[diag] done — you can type ROS 1 commands here, e.g.:"
echo "  rostopic list"
echo "  rosrun tf tf_echo /camera_init /aft_mapped"
'\'' C-m

    # ---------- Control window ----------
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[control] waiting for bag playback to finish"
tmux wait-for BAG_DONE
echo "[control] bag playback finished — shutting down"

# Give Voxel-SLAM a moment to process remaining queued scans
sleep 5

# Graceful stop: Ctrl+C to each pane
# Pane layout: 0=roscore, 1=voxel_slam+rviz, 2=recorder, 3=play, 4=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.2 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
sleep 3

echo "[control] force-killing remaining processes..."
pkill -9 voxelslam   2>/dev/null || true
pkill -9 rviz        2>/dev/null || true
pkill -9 rosmaster   2>/dev/null || true
pkill -9 rosout      2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e DISPLAY="$DISPLAY" \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash
    rosrun voxelslam_to_hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-Voxel-SLAM\" \
      \"$CLOUD_TOPIC\" \
      \"$TF_CHILD_FRAME\"
  "

echo "=== DONE ==="
