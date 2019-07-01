#!/bin/bash

#
# Copyright (c) 2018-2019 Arm Limited. All rights reserved.
#

#
# Script to build all of the required software for the Arm NN examples
#

function IsPackageInstalled() {
    dpkg -s "$1" > /dev/null 2>&1
}

usage() { 
    echo "Usage: $0 [-o <0|1> ]" 1>&2 
    echo "   -o option will enable or disable OpenCL" 1>&2
    exit 1 
}

OpenCL=1
# Simple command line arguments
while getopts ":o:h" opt; do
    case "${opt}" in
        o)
            OpenCL=${OPTARG}
            ;;
        h)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

# save history to logfile
exec > >(tee -i logfile)
exec 2>&1

echo "Building Arm NN in $HOME/armnn-devenv"

# Start from home directory
cd $HOME 

# if nothing, found make a new diectory
[ -d armnn-devenv ] || mkdir armnn-devenv


# check for previous installation, HiKey 960 is done as a mount point so don't 
# delete all from top level, drop down 1 level
while [ -d armnn-devenv/pkg ]; do
    read -p "Do you wish to remove the existing armnn-devenv build environment? " yn
    case $yn in
        [Yy]*) rm -rf armnn-devenv/pkg armnn-devenv/ComputeLibrary armnn-devenv/armnn ; break ;;
        [Nn]*) echo "Exiting " ; exit;;
        *) echo "Please answer yes or no.";;
    esac
done

cd armnn-devenv 

# packages to install 
packages="git wget curl autoconf autogen automake libtool scons make cmake gcc g++ unzip bzip2"
# for package in $packages; do
#     if ! IsPackageInstalled $package; then
#         sudo apt-get install -y $package
#     fi
# done

# number of CPUs and memory size for make -j
NPROC=`grep -c ^processor /proc/cpuinfo`
MEM=`awk '/MemTotal/ {print $2}' /proc/meminfo`

Arch=arm64-v8a
PREFIX=aarch64-linux-android-

# Download the Android NDK

mkdir -p pkg/toolchains
echo "downloading Android NDK"
pushd pkg/toolchains

AndroidNativeKitRev=17b
AndroidNativeKitApi=26

wget https://dl.google.com/android/repository/android-ndk-r$AndroidNativeKitRev\-linux-x86_64.zip
unzip android-ndk-r$AndroidNativeKitRev\-linux-x86_64.zip
rm android-ndk-r$AndroidNativeKitRev\-linux-x86_64.zip

NDK=$PWD/android-ndk-r$AndroidNativeKitRev

# Make a standalone toolchain
$NDK/build/tools/make_standalone_toolchain.py  \
--arch arm64  \
--api $AndroidNativeKitApi  \
--stl=libc++  \
--install-dir=$PWD/aarch64-android-r$AndroidNativeKitRev

export PATH=$PWD/aarch64-android-r$AndroidNativeKitRev\/bin:$PATH

popd

# Boost

mkdir -p pkg/boost
echo "building boost"
pushd pkg/boost

wget https://dl.bintray.com/boostorg/release/1.64.0/source/boost_1_64_0.tar.bz2
tar xf boost_1_64_0.tar.bz2
cd boost_1_64_0
./bootstrap.sh --prefix=$HOME/armnn-devenv/pkg/boost/install

Toolset=""
cp tools/build/example/user-config.jam project-config.jam
sed -i "/# using gcc ;/c using gcc : arm : ${PREFIX}clang++ ;" project-config.jam
Toolset="toolset=gcc-arm"

./b2 install link=static cxxflags=-fPIC $Toolset --with-filesystem --with-test --with-log --with-program_options --prefix=$HOME/armnn-devenv/pkg/boost/install

popd

# Arm Compute Library

git clone https://github.com/ARM-software/ComputeLibrary.git

echo "building Arm CL"
pushd ComputeLibrary

scons arch=$Arch neon=1 opencl=$OpenCL embed_kernels=$OpenCL Werror=0 \
  extra_cxx_flags="-fPIC" benchmark_tests=0 examples=0 validation_tests=0 \
  os=android -j $NPROC

popd

# TensorFlow and Google protobuf
# Latest TensorFlow had a problem, udpate branch as needed

pushd pkg
mkdir install
#git clone --branch 3.5.x https://github.com/protocolbuffers/protobuf.git
git clone https://github.com/protocolbuffers/protobuf.git
git clone https://github.com/tensorflow/tensorflow.git

# build Protobuf
cd protobuf
./autogen.sh


# Extra protobuf build for host machine
mkdir host-build ; cd host-build
../configure --prefix=$HOME/armnn-devenv/pkg/host
make -j $NPROC
make install
make clean
cd ..

mkdir build ; cd build
../configure --prefix=$HOME/armnn-devenv/pkg/install --host=aarch64-linux-android CC=$PREFIX\clang CXX=$PREFIX\clang++ --with-protoc=$HOME/armnn-devenv/pkg/host/bin/protoc

make -j $NPROC
make install

popd

# build Google Flatbuffers

pushd pkg

Version=1.10.0
wget https://github.com/google/flatbuffers/archive/v$Version\.zip
unzip v$Version\.zip
rm v$Version\.zip
cd flatbuffers-$Version
mkdir build ; cd build

CC=$PREFIX\clang  \
CXX=$PREFIX\clang++  \
CXX_FLAGS="-fPIE -fPIC"  \
cmake ..  \
-DFLATBUFFERS_BUILD_TESTS=0  \
-DFLATBUFFERS_BUILD_FLATC=0  \
-DCMAKE_BUILD_TYPE=Release  \
-DCMAKE_C_COMPILER_FLAGS=-fPIC  \
-DCMAKE_INSTALL_PREFIX=$HOME/armnn-devenv/pkg/install/

make -j $NPROC
make install
make clean
cd ../..

popd

# Arm NN

git clone https://github.com/ARM-software/armnn.git

pushd pkg/tensorflow/

$HOME/armnn-devenv/armnn/scripts/generate_tensorflow_protobuf.sh $HOME/armnn-devenv/pkg/tensorflow-protobuf $HOME/armnn-devenv/pkg/host

popd

# Arm NN
pushd armnn
mkdir build ; cd build

CC=$PREFIX\clang  \
CXX=$PREFIX\clang++  \
CXX_FLAGS="-fPIE -fPIC"  \
cmake ..  \
-DCMAKE_SYSTEM_NAME=Android \
-DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
-DCMAKE_ANDROID_STANDALONE_TOOLCHAIN=$HOME/armnn-devenv/pkg/toolchains/aarch64-android-r17b/ \
-DARMCOMPUTE_ROOT=$HOME/armnn-devenv/ComputeLibrary/ \
-DARMCOMPUTE_BUILD_DIR=$HOME/armnn-devenv/ComputeLibrary/build \
-DBOOST_ROOT=$HOME/armnn-devenv/pkg/boost/install/ \
-DTF_GENERATED_SOURCES=$HOME/armnn-devenv/pkg/tensorflow-protobuf/  \
-DBUILD_TF_PARSER=1 \
-DPROTOBUF_ROOT=$HOME/armnn-devenv/pkg/install   \
-DPROTOBUF_INCLUDE_DIRS=$HOME/armnn-devenv/pkg/install/include   \
-DARMCOMPUTENEON=1  \
-DARMCOMPUTECL=$OpenCL \
-DPROTOBUF_LIBRARY_DEBUG=$HOME/armnn-devenv/pkg/install/lib/libprotobuf.so \
-DPROTOBUF_LIBRARY_RELEASE=$HOME/armnn-devenv/pkg/install/lib/libprotobuf.so \
-DBUILD_TF_LITE_PARSER=1   \
-DTF_LITE_GENERATED_PATH=$HOME/armnn-devenv/pkg/tensorflow/tensorflow/lite/schema  \
-DFLATBUFFERS_ROOT=$HOME/armnn-devenv/pkg/install  \
-DCMAKE_CXX_FLAGS="-Wno-error=sign-conversion" \
-DCMAKE_BUILD_TYPE=Debug

make -j $NPROC

popd

echo "done, everything in armnn-devenv/"
cd ..

