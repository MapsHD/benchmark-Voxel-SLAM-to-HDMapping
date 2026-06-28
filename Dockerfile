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

# ── Build catkin workspace (Voxel-SLAM + livox_ros_driver + converter) ───────
WORKDIR /ros_ws

COPY ./src/Voxel-SLAM             ./src/Voxel-SLAM
COPY ./src/livox_ros_driver       ./src/livox_ros_driver
COPY ./src/voxelslam-to-hdmapping ./src/voxelslam-to-hdmapping

# Build in stages so the livox_ros_driver message (CustomMsg) exists before
# Voxel-SLAM is configured, and so the RViz plugin (VoxelSLAMPointCloud2,
# shipped in the same submodule but not needed here) is skipped.
RUN source /opt/ros/noetic/setup.bash && \
    catkin_make --only-pkg-with-deps livox_ros_driver   -DCMAKE_BUILD_TYPE=Release -j$(nproc) && \
    catkin_make --only-pkg-with-deps voxel_slam         -DCMAKE_BUILD_TYPE=Release -j$(nproc) && \
    catkin_make --only-pkg-with-deps voxelslam_to_hdmapping -DCMAKE_BUILD_TYPE=Release -j$(nproc)

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
