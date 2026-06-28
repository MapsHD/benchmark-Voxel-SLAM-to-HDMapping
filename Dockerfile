FROM ubuntu:20.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    apt-transport-https \
    ca-certificates \
    wget \
    libeigen3-dev \
    libboost-all-dev \
    libomp-dev \
    libtbb-dev \
    libpcl-dev \
    libopencv-dev \
    libyaml-cpp-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 1 Noetic ─────────────────────────────────────────────────────────────
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-noetic-desktop-full \
    ros-noetic-tf \
    ros-noetic-tf2-msgs \
    ros-noetic-tf-conversions \
    ros-noetic-eigen-conversions \
    ros-noetic-pcl-conversions \
    ros-noetic-pcl-ros \
    ros-noetic-message-filters \
    ros-noetic-rosbag \
    ros-noetic-rosbag-storage \
    python3-rosdep \
    python3-rosinstall \
    python3-rosinstall-generator \
    python3-wstool \
    python3-catkin-tools \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (used to convert ROS 2 bags to ROS 1, if needed) ─────────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── GTSAM 4.0.3 (Voxel-SLAM links against gtsam) ─────────────────────────────
#    Build against the system Eigen 3.3.7 and WITHOUT -march=native to avoid
#    Eigen alignment mismatches/segfaults when mixed with PCL/ROS objects.
WORKDIR /tmp
RUN git clone https://github.com/borglab/gtsam.git && \
    cd gtsam && \
    git checkout 4.0.3 && \
    mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DGTSAM_USE_SYSTEM_EIGEN=ON \
      -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF \
      -DGTSAM_BUILD_TESTS=OFF \
      -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF \
      -DGTSAM_BUILD_UNSTABLE=OFF && \
    make -j$(nproc) && make install && \
    ldconfig && \
    cd / && rm -rf /tmp/gtsam

# ── Livox-SDK (required by livox_ros_driver) ─────────────────────────────────
WORKDIR /tmp
RUN git clone https://github.com/Livox-SDK/Livox-SDK.git && \
    cd Livox-SDK/build && \
    cmake .. && \
    make -j$(nproc) && make install && \
    ldconfig && \
    cd / && rm -rf /tmp/Livox-SDK

# ── Qt5 (required to build the VoxelSLAMPointCloud2 RViz plugin) ─────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    qtbase5-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Build catkin workspace (Voxel-SLAM + livox_ros_driver + converter) ───────
WORKDIR /ros_ws

COPY ./src/Voxel-SLAM             ./src/Voxel-SLAM
COPY ./src/livox_ros_driver       ./src/livox_ros_driver
COPY ./src/voxelslam-to-hdmapping ./src/voxelslam-to-hdmapping

# Extra sensor profiles added by this benchmark (kept out of the pristine
# upstream submodule). e.g. livox_pc2 = Livox scans exported as PointCloud2.
COPY ./overlay/config/ ./src/Voxel-SLAM/VoxelSLAM/config/
COPY ./overlay/launch/ ./src/Voxel-SLAM/VoxelSLAM/launch/

# Drop the deprecated leading slashes from the odometry TF broadcast. Voxel-SLAM
# publishes /camera_init -> /aft_mapped, but its point clouds and the back.rviz
# config use the slash-less "camera_init" / "aft_mapped". The mismatch makes
# RViz report 'Fixed Frame [camera_init] does not exist' and the Axes/cloud
# displays fail to resolve. Publishing slash-less frames fixes the live view.
RUN sed -i 's|"/camera_init", "/aft_mapped"|"camera_init", "aft_mapped"|' \
    src/Voxel-SLAM/VoxelSLAM/src/voxelslam.cpp && \
    grep -q '"camera_init", "aft_mapped"' src/Voxel-SLAM/VoxelSLAM/src/voxelslam.cpp

# Build the livox_ros_driver message (CustomMsg) first, then everything else:
# the Voxel-SLAM node, the converter, and the VoxelSLAMPointCloud2 RViz plugin
# (required by the back.rviz config used for the live benchmark visualization).
#
# The second invocation explicitly resets CATKIN_WHITELIST_PACKAGES so that the
# whitelist set by --only-pkg-with-deps in the first call does NOT persist in
# the CMake cache and silently restrict the build to livox_ros_driver only.
# The final guard fails the image build loudly if the RViz plugin .so is missing.
RUN source /opt/ros/noetic/setup.bash && \
    catkin_make --only-pkg-with-deps livox_ros_driver \
        -DCMAKE_BUILD_TYPE=Release -j$(nproc) && \
    catkin_make -DCATKIN_WHITELIST_PACKAGES="" \
        -DCMAKE_BUILD_TYPE=Release -j$(nproc) && \
    test -f /ros_ws/devel/lib/voxel_slam/voxelslam && \
    test -f /ros_ws/devel/lib/voxelslam_to_hdmapping/listener && \
    test -f /ros_ws/devel/lib/libvoxelslam_pointcloud2.so && \
    echo "[build] voxel_slam node, converter, and RViz plugin all present"

# pluginlib resolves the <library path="lib/libvoxelslam_pointcloud2"> entry in
# plugin_description.xml relative to the package directory. In a catkin *devel*
# workspace the package dir is the source tree, but the built .so lives in
# devel/lib, so expose it at the package-relative path RViz expects.
RUN mkdir -p /ros_ws/src/Voxel-SLAM/VoxelSLAMPointCloud2/lib && \
    ln -sf /ros_ws/devel/lib/libvoxelslam_pointcloud2.so \
           /ros_ws/src/Voxel-SLAM/VoxelSLAMPointCloud2/lib/libvoxelslam_pointcloud2.so

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros_ws

RUN echo "source /opt/ros/noetic/setup.bash"   >> /root/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /root/.bashrc && \
    echo "source /opt/ros/noetic/setup.bash"   >> /home/ros/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /home/ros/.bashrc

CMD ["bash"]
