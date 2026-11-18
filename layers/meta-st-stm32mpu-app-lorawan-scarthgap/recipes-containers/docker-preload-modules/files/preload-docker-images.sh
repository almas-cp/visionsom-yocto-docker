#!/bin/sh
IMAGE_DIR="/opt/preloaded-modules"

if [ -d "$IMAGE_DIR" ]; then
    echo "Loading pre-provisioned Docker modules..."
    for tarball in $IMAGE_DIR/*.tar; do
        if [ -f "$tarball" ]; then
            echo "Loading $tarball..."
            docker load -i "$tarball"
            if [ $? -eq 0 ]; then
                echo "Successfully loaded $tarball. Deleting file to free up space."
                rm -f "$tarball"
            else
                echo "Failed to load $tarball"
            fi
        fi
    done
    
    # Remove directory if empty
    rmdir "$IMAGE_DIR" 2>/dev/null
    echo "Module loading complete."
fi
