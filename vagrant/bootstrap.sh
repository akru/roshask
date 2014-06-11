#!/usr/bin/env bash

# Install ROS Hydro
echo "deb http://packages.ros.org/ros/ubuntu raring main" > /etc/apt/sources.list.d/ros-latest.list

wget http://packages.ros.org/ros.key -O - | sudo apt-key add -

apt-get update

apt-get install -y ros-hydro-ros-base

su vagrant <<EOF
rosdep init
rosdep update
echo "source /opt/ros/hydro/setup.bash" >> ~/.bashrc
EOF

# source ~/.bashrc

# Install rosinstall and support for add-apt-repository for working
# with PPAs
apt-get install -y python-rosinstall python-software-properties software-properties-common

# Get GHC and cabal-install from Herbert's PPA
add-apt-repository ppa:hvr/ghc
sed 's/ raring / precise /' /etc/apt/sources.list.d/hvr-ghc-raring.list > /etc/apt/sources.list.d/hvr-ghc-precise.list
apt-get update
apt-get install -y ghc-7.6.3
apt-get install -y cabal-install-1.20

# Configure SSH
su vagrant <<EOF
echo "PATH=/opt/ghc/7.6.3/bin:$PATH" >> ~/.bashrc
echo "Host github.com" > ~/.ssh/config
echo "User git" >> ~/.ssh/config
# echo "IdentityFile ~/.ssh/github" >> ~/.ssh/config
echo "IdentityFile /vagrant/vagrant/ssh/github" >> ~/.ssh/config
EOF
