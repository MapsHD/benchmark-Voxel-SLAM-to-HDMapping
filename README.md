## Hint

Please change branch to [Bunker-DVI-Dataset-reg-1](https://github.com/MapsHD/benchmark-Voxel-SLAM-to-HDMapping/tree/Bunker-DVI-Dataset-reg-1) for quick experiment.

## Example Dataset:

Download the dataset from [Bunker DVI Dataset](https://charleshamesse.github.io/bunker-dvi-dataset/)

# benchmark-Voxel-SLAM-to-HDMapping

Runs the [Voxel-SLAM](https://github.com/hku-mars/Voxel-SLAM) LiDAR-Inertial
SLAM system on a ROS 1 bag file and converts the output to an
[HDMapping](https://github.com/MapsHD/HDMapping) session.

Voxel-SLAM is *A Complete, Accurate, and Versatile LiDAR-Inertial SLAM System*
by HKU-MARS ([paper](https://arxiv.org/abs/2410.08935)).

## Prerequisites

- Docker
- A ROS 1 bag containing a LiDAR topic and an IMU topic matching the topic names
  declared in the chosen Voxel-SLAM config (ROS 2 bags are automatically
  converted to ROS 1 format). For the Livox profiles the LiDAR topic must be a
  `livox_ros_driver/CustomMsg`; the other profiles expect a
  `sensor_msgs/PointCloud2`.

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-Voxel-SLAM-to-HDMapping.git --recursive
cd benchmark-Voxel-SLAM-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t voxelslam_noetic .
```

This installs:
- Ubuntu 20.04 + ROS 1 Noetic
- Eigen3, PCL, OpenCV, Boost, OpenMP, TBB
- GTSAM 4.0.3 (system Eigen, no `-march=native`)
- Livox-SDK + `livox_ros_driver` (provides `CustomMsg`)
- Voxel-SLAM (compiled from submodule)
- catkin workspace with `voxel_slam` and `voxelslam_to_hdmapping`

The build takes several minutes on first run (GTSAM is built from source).

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros1-voxelslam.sh
./docker_session_run-ros1-voxelslam.sh /path/to/input.bag /path/to/output/dir
```

Or with no arguments to use a GUI file selector (requires `zenity`):

```bash
./docker_session_run-ros1-voxelslam.sh
```

By default the script uses the `avia` profile. Pick a different one with the
`SENSOR` environment variable, e.g.:

```bash
SENSOR=hesai ./docker_session_run-ros1-voxelslam.sh /path/to/input.bag /path/to/output/dir
```

Available sensor profiles (from the `Voxel-SLAM/VoxelSLAM/config/` directory):

| `SENSOR`   | Launch file              | LiDAR type | Config LiDAR topic        | Config IMU topic       | Typical dataset      |
|------------|--------------------------|------------|---------------------------|------------------------|----------------------|
| `avia`     | `vxlm_avia.launch`       | Livox Avia | `/livox/lidar`            | `/livox/imu`           | Livox Avia handheld  |
| `avia_fly` | `vxlm_avia_fly.launch`   | Livox Avia | `/livox/lidar`            | `/livox/imu`           | MARS dataset (drone) |
| `mid360`   | `vxlm_mid360.launch`     | Livox Mid360 | `/livox/lidar`          | `/livox/imu`           | Livox Mid360         |
| `hesai`    | `vxlm_hesai.launch`      | Hesai Pandar | `/hesai/pandar`         | `/alphasense/imu`      | HILTI 2023           |
| `ouster`   | `vxlm_ouster.launch`     | Ouster OS-1 | `/os1_cloud_node/points` | `/os1_cloud_node/imu`  | Ouster OS-1          |
| `velodyne` | `vxlm_velodyne.launch`   | Velodyne   | `/velodyne_points`        | `/imu/data`            | Velodyne             |

If your bag uses different topic names than the profile's config, remap them on
playback with `LIDAR_TOPIC` / `IMU_TOPIC` (the value is the name **in the bag**):

```bash
SENSOR=velodyne LIDAR_TOPIC=/points_raw IMU_TOPIC=/imu/data_raw \
  ./docker_session_run-ros1-voxelslam.sh /path/to/input.bag /path/to/output/dir
```

**What happens:**

The script opens a Docker container with a tmux session containing five panes
and a control window:

| Pane | Role |
|------|------|
| 0 | `roscore` |
| 1 | `roslaunch voxel_slam <profile>.launch` — subscribes to the LiDAR + IMU topics, broadcasts the `camera_init → aft_mapped` TF, publishes `/map_scan` (+ RViz) |
| 2 | `rosbag record /map_scan /tf` — captures the per-scan world cloud and the pose TF |
| 3 | `rosbag play --clock` — plays your input bag with simulated clock |
| 4 | diagnostics — shows active topics and publishing rates |
| control | auto-shutdown — waits for playback to finish, then stops all nodes |

After playback completes, the control window automatically stops the recorder,
kills all nodes, and exits tmux. A second Docker run then converts the recorded
bag into the HDMapping session format.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-Voxel-SLAM/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
scan_lio_1.laz
...
session.json
trajectory_lio_0.csv
trajectory_lio_1.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on Voxel-SLAM

Unlike LIO-Livox / EllipseLIO / D-LIO, Voxel-SLAM does **not** publish a
`nav_msgs/Odometry` topic. Its outputs are:

| Topic / TF | Type | Meaning |
|------------|------|---------|
| `/map_scan` | `sensor_msgs/PointCloud2` | the current scan, already expressed in the `camera_init` (world) frame |
| `camera_init → aft_mapped` (on `/tf`) | `tf2_msgs/TFMessage` | the current 6-DoF body pose |
| `/map_path`, `/map_cmap`, `/map_pmap`, `/map_init` | `sensor_msgs/PointCloud2` | visualization-only trajectory / map clouds |

Because `/map_scan` is already in the world frame, the converter does **not**
re-apply the pose to the points — it only uses the `camera_init → aft_mapped`
TF to build the per-chunk trajectory files. Both the cloud and the TF are
published back-to-back with the same `ros::Time::now()` stamp, so under the
simulated clock (`rosbag play --clock`) they share a common timeline.

The input topic names are configured **inside the YAML config file** (in
`Voxel-SLAM/VoxelSLAM/config/<profile>.yaml`, under the `General:` section):

```yaml
General:
  lid_topic: "/your/lidar/topic"
  imu_topic: "/your/imu/topic"
  lidar_type: 0   # 0 LIVOX, 1 VELODYNE, 2 OUSTER, 3 HESAI
  extrinsic_tran: [x, y, z]
  extrinsic_rota: [r00, r01, ... r22]
```

The recorded topic and the TF child frame are also tunable via env vars:

| Variable | Meaning | Default |
|----------|---------|---------|
| `CLOUD_TOPIC`     | Voxel-SLAM per-scan cloud (world frame) | `/map_scan` |
| `TF_CHILD_FRAME`  | TF child frame carrying the pose         | `aft_mapped` |

This benchmark captures Voxel-SLAM's **online** odometry output (one world-frame
scan + pose per frame), consistent with the other LIO benchmarks in this repo.
Voxel-SLAM's offline global bundle adjustment (`rosparam set finish true`) and
multi-session loop closure refine the map further but republish on
`/map_pmap` / `/map_true`, so they are not part of the recorded session.

## Contact

januszbedkowski@gmail.com
