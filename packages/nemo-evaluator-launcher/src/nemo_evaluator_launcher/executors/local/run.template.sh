# SPDX-FileCopyrightText: Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

{% if container_runtime == "apptainer" %}
# check if apptainer exists
command -v apptainer >/dev/null 2>&1 || { echo 'apptainer not found'; exit 1; }

# Helper function to ensure image exists
ensure_image() {
    local IMAGE_URI="$1"
    local CACHE_DIR="$2"

    # If image is a local file, return it
    if [ -f "$IMAGE_URI" ]; then
        echo "$IMAGE_URI"
        return
    fi

    # Convert URI to filename (replace / and : with _)
    local FILENAME=$(echo "$IMAGE_URI" | sed 's|/|_|g' | sed 's|:|__|g')
    if [[ "$FILENAME" != *.sing ]]; then
        FILENAME="${FILENAME}.sing"
    fi

    local TARGET_PATH="${CACHE_DIR}/${FILENAME}"

    if [ -f "$TARGET_PATH" ]; then
        echo "$TARGET_PATH"
        return
    fi

    # Image doesn't exist, build it
    echo "Building Apptainer image $TARGET_PATH from $IMAGE_URI..." >&2
    # Ensure cache dir exists
    mkdir -p "$CACHE_DIR"

    # Check if we are running as root (not common on HPC) or have fakeroot
    # The prompt suggests using --fakeroot
    apptainer build --fakeroot "$TARGET_PATH" "docker://$IMAGE_URI" >&2

    if [ $? -eq 0 ]; then
        echo "$TARGET_PATH"
    else
        echo "Failed to build image" >&2
        exit 1
    fi
}

# Image cache directory
{% if apptainer_image_cache_dir %}
IMAGE_CACHE_DIR="{{ apptainer_image_cache_dir }}"
{% else %}
IMAGE_CACHE_DIR="$(pwd)/apptainer_images"
{% endif %}
mkdir -p "$IMAGE_CACHE_DIR"

{% else %}
# check if docker exists
command -v docker >/dev/null 2>&1 || { echo 'docker not found'; exit 1; }
{% endif %}

# Initialize: remove killed jobs file from previous runs
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
killed_jobs_file="$script_dir/killed_jobs.txt"
rm -f "$killed_jobs_file"

# Create all directories and stdout.log files upfront before any container starts
{% for task in evaluation_tasks %}
task_dir="{{ task.output_dir }}"
artifacts_dir="$task_dir/artifacts"
logs_dir="$task_dir/logs"

mkdir -m 777 -p "$task_dir"
mkdir -m 777 -p "$artifacts_dir"
mkdir -m 777 -p "$logs_dir"
# Create stdout.log file upfront
touch "$logs_dir/client_stdout.log"
chmod 666 "$logs_dir/client_stdout.log"
{% endfor %}

{% for task in evaluation_tasks %}
# {{ task.job_id }} {{ task.name }}

task_dir="{{ task.output_dir }}"
artifacts_dir="$task_dir/artifacts"
logs_dir="$task_dir/logs"

mkdir -m 777 -p "$task_dir"
mkdir -m 777 -p "$artifacts_dir"
mkdir -m 777 -p "$logs_dir"

# Check if this job was killed
if [ -f "$killed_jobs_file" ] && grep -q "^{{ task.job_id }}$" "$killed_jobs_file"; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Job {{ task.job_id }} ({{ task.name }}) was killed, skipping execution" | tee -a "$logs_dir/stdout.log"
else
    # Create pre-start stage file
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$logs_dir/stage.pre-start"

    # Debug contents of the eval factory command's config
    {{ task.eval_factory_command_debug_comment | indent(4) }}

    {% if container_runtime == "apptainer" %}
    # Resolve images for Apptainer
    {% if task.deployment %}
    DEPLOYMENT_IMAGE=$(ensure_image "{{ task.deployment.image }}" "$IMAGE_CACHE_DIR")
    {% endif %}
    EVAL_IMAGE=$(ensure_image "{{ task.eval_image }}" "$IMAGE_CACHE_DIR")
    {% endif %}

    # Run with {{ container_runtime }}
    (
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$logs_dir/stage.running"
        {% if task.deployment %}
            {% if container_runtime == "apptainer" %}
            # Apptainer deployment
            # Start instance
            SERVER_INSTANCE_NAME="server_{{ task.job_id | replace('.', '_') }}"

            # Start the instance
            apptainer instance start --nv \
            {% for mount in task.deployment.mounts -%}
            --bind {{ mount }} \
            {% endfor -%}
            "$DEPLOYMENT_IMAGE" "$SERVER_INSTANCE_NAME" > "$logs_dir/server_stdout.log" 2>&1

            # Run command in instance in background
            apptainer exec --nv \
            {% for env_var in task.deployment.env_vars -%}
            --env {{ env_var }} \
            {% endfor -%}
            "instance://$SERVER_INSTANCE_NAME" {{ task.deployment.command }} >> "$logs_dir/server_stdout.log" 2>&1 &

            SERVER_PID=$!
            SERVER_CONTAINER_NAME="$SERVER_INSTANCE_NAME"
            {% else %}
            # Docker deployment
            docker run --rm --shm-size=100g --gpus all {{ task.deployment.extra_docker_args }} \
            --name {{ task.deployment.container_name }} --entrypoint '' \
            -p {{ task.deployment.port }}:{{ task.deployment.port }} \
            {% for env_var in task.deployment.env_vars -%}
            -e {{ env_var }} \
            {% endfor -%}
            {% for mount in task.deployment.mounts -%}
            -v {{ mount }} \
            {% endfor -%}
            {{ task.deployment.image }} \
            {{ task.deployment.command }} > "$logs_dir/server_stdout.log" 2>&1 &

            SERVER_PID=$!
            SERVER_CONTAINER_NAME="{{ task.deployment.container_name }}"
            {% endif %}

        date
        # wait for the server to initialize
        TIMEOUT=600
        ELAPSED=0
        while [[ "$(curl -s -o /dev/null -w "%{http_code}" {{ task.deployment.health_url }})" != "200" ]]; do
            kill -0 $SERVER_PID 2>/dev/null || { echo "Server process $SERVER_PID died"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) 1" > "$logs_dir/stage.exit"; exit 1; }
            [ $ELAPSED -ge $TIMEOUT ] && { echo "Health check timeout after ${TIMEOUT}s"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) 1" > "$logs_dir/stage.exit"; exit 1; }
            sleep 5
            ELAPSED=$((ELAPSED + 5))
        done
        date

        {% endif %}

        {% if container_runtime == "apptainer" %}
        # Apptainer client
        
        # Prepare a script file on the host (in artifacts dir) to avoid quoting hell and path issues
        # The artifacts dir is mounted to /results in the container
        cat << 'CONTAINER_SCRIPT' > "$artifacts_dir/entrypoint.sh"
#!/bin/bash
# Critical: Add the venv path where eval-factory lives
export PATH=$PATH:/opt/venv/bin

# Critical: Prevent proxy from intercepting localhost traffic (fixes Squid 404/Connection Refused)
export no_proxy="localhost,127.0.0.1,::1,${no_proxy}"
export NO_PROXY="localhost,127.0.0.1,::1,${NO_PROXY}"

# Ensure we are in the results directory so generated files (pre_cmd.sh) are writable
cd /results

{{ task.eval_factory_command }}

exit_code=$?
chmod 777 -R /results || true

if [ "$exit_code" -ne 0 ]; then
    echo "The evaluation container failed with exit code $exit_code" >&2
    exit "$exit_code"
fi
echo "Container completed successfully" >&2
exit 0
CONTAINER_SCRIPT

        chmod +x "$artifacts_dir/entrypoint.sh"

        # Use 'exec' instead of 'run' to bypass entrypoint issues
        apptainer exec --nv \
          --bind "$artifacts_dir":/results \
          {% if task.dataset_mount_host and task.dataset_mount_container -%}
          --bind "{{ task.dataset_mount_host }}:{{ task.dataset_mount_container }}" \
          {% endif -%}
          {% for env_var in task.env_vars -%}
          --env {{ env_var }} \
          {% endfor -%}
          "$EVAL_IMAGE" \
          /bin/bash /results/entrypoint.sh > "$logs_dir/client_stdout.log" 2>&1
        
        {% else %}
        # Docker client
        docker run --rm --shm-size=100g {{ extra_docker_args }} \
        {% if task.deployment %}--network container:$SERVER_CONTAINER_NAME \{% endif %}--name {{ task.client_container_name }} \
      --volume "$artifacts_dir":/results \
      {% if task.dataset_mount_host and task.dataset_mount_container -%}
      --volume "{{ task.dataset_mount_host }}:{{ task.dataset_mount_container }}" \
      {% endif -%}
      {% for env_var in task.env_vars -%}
      -e {{ env_var }} \
      {% endfor -%}
      {{ task.eval_image }} \
      bash -c '
        {{ task.eval_factory_command | indent(8) }} ;
        exit_code=$?
        chmod 777 -R /results;
        if [ "$exit_code" -ne 0 ]; then
            echo "The evaluation container failed with exit code $exit_code" >&2;
            exit "$exit_code";
        fi;
        echo "Container completed successfully" >&2;
        exit 0;
      ' > "$logs_dir/client_stdout.log" 2>&1
      {% endif %}
    exit_code=$?

    {% if task.deployment %}
    # Stop the server
    {% if container_runtime == "apptainer" %}
    apptainer instance stop "$SERVER_INSTANCE_NAME" 2>/dev/null || true
    # Also kill the background process if it's still running
    kill $SERVER_PID 2>/dev/null || true
    {% else %}
    docker stop $SERVER_CONTAINER_NAME 2>/dev/null || true
    {% endif %}
    {% endif %}

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $exit_code" > "$logs_dir/stage.exit"
) >> "$logs_dir/stdout.log" 2>&1


{% if auto_export_destinations %}
# Monitor job completion and auto-export
(
    # Give it a moment to ensure file is fully written
    sleep 1

    exit_code=$(tail -1 "$logs_dir/stage.exit" | cut -d' ' -f2)
    if [ "$exit_code" = "0" ]; then
        # Log auto-export activity to task logs
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Job {{ task.job_id }} completed successfully. Starting auto-export..." >> "$logs_dir/stdout.log"

        {% for dest in auto_export_destinations %}
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Exporting job {{ task.job_id }} to {{ dest }}..." >> "$logs_dir/stdout.log"
        nemo-evaluator-launcher export {{ task.job_id }} --dest {{ dest }} >> "$logs_dir/stdout.log" 2>&1
        if [ $? -eq 0 ]; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Export to {{ dest }} completed successfully" >> "$logs_dir/stdout.log"
        else
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Export to {{ dest }} failed" >> "$logs_dir/stdout.log"
        fi
        {% endfor %}

        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Auto-export completed for job {{ task.job_id }}" >> "$logs_dir/stdout.log"
    else
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Job {{ task.job_id }} failed with exit code $exit_code. Skipping auto-export." >> "$logs_dir/stdout.log"
    fi
)

{% endif %}
fi


{% endfor %}