#!/bin/bash


# The Docker Project – Centered Arrow UI
######################################

# Global variables
USE_SUDO_FOR_DOCKER=0
ARROW_SELECTED_ITEM=""
CENTERED_READ_RESULT=""

clear_screen() {
    clear 2>/dev/null || printf "\033[H\033[2J"
}

# Centered read: prompt on one line, input below, stored in CENTERED_READ_RESULT
centered_read() {
    local prompt="$1"
    local cols=$(tput cols)
    local lines=$(tput lines)
    local start_y=$(( (lines - 2) / 2 ))
    (( start_y < 1 )) && start_y=1
    local prompt_x=$(( (cols - ${#prompt}) / 2 ))
    (( prompt_x < 0 )) && prompt_x=0
    tput cup $start_y $prompt_x
    printf "%s" "$prompt" >&2
    tput cup $((start_y + 1)) $prompt_x
    read -r CENTERED_READ_RESULT
    clear_screen
}

# Show centered message(s) and wait for Enter
show_message() {
    local lines=("$@")
    clear_screen
    local cols=$(tput cols)
    local lines_count=${#lines[@]}
    local start_y=$(( ($(tput lines) - lines_count) / 2 ))
    (( start_y < 1 )) && start_y=1
    local i=0
    for line in "${lines[@]}"; do
        local start_x=$(( (cols - ${#line}) / 2 ))
        (( start_x < 0 )) && start_x=0
        tput cup $((start_y + i)) $start_x
        printf "%s" "$line"
        ((i++))
    done
    local pause_row=$(( start_y + i + 1 ))
    local pause_text="Press Enter to continue..."
    local pause_x=$(( (cols - ${#pause_text}) / 2 ))
    (( pause_x < 0 )) && pause_x=0
    tput cup $pause_row $pause_x
    printf "\e[7m%s\e[0m" "$pause_text" >&2
    read -r dummy
    clear_screen
}

# Pause at bottom of screen (for logs)
bottom_pause() {
    local cols=$(tput cols)
    local lines=$(tput lines)
    local pause_text="Press Enter to continue..."
    local pause_x=$(( (cols - ${#pause_text}) / 2 ))
    (( pause_x < 0 )) && pause_x=0
    tput cup $(( lines - 3 )) $pause_x
    printf "\e[7m%s\e[0m" "$pause_text" >&2
    read -r dummy
    clear_screen
}

# Custom arrow-key menu
arrow_menu() {
    local title="$1"
    shift
    local -a items=("$@")
    local selected=0
    local key
    while true; do
        clear_screen
        local cols=$(tput cols)
        local lines=$(tput lines)
        local total_height=$(( ${#items[@]} + 3 ))
        local start_y=$(( (lines - total_height) / 2 ))
        (( start_y < 1 )) && start_y=1
        tput cup $start_y $(( (cols - ${#title}) / 2 ))
        printf "%s" "$title"
        local sep="===================================="
        tput cup $((start_y + 1)) $(( (cols - ${#sep}) / 2 ))
        printf "%s" "$sep"
        for i in "${!items[@]}"; do
            local item="${items[$i]}"
            local line
            if [[ $i -eq $selected ]]; then
                line="> ${item} <"
            else
                line="  ${item}  "
            fi
            local start_x=$(( (cols - ${#line}) / 2 ))
            (( start_x < 0 )) && start_x=0
            tput cup $((start_y + 2 + i)) $start_x
            if [[ $i -eq $selected ]]; then
                printf "\e[7m%s\e[0m" "$line"
            else
                printf "%s" "$line"
            fi
        done
        read -s -n 1 key
        if [[ $key == $'\x1b' ]]; then
            read -s -n 1 key2
            if [[ $key2 == '[' ]]; then
                read -s -n 1 key3
                case $key3 in
                    'A') ((selected--)); [[ $selected -lt 0 ]] && selected=$(( ${#items[@]} - 1 ));;
                    'B') ((selected++)); [[ $selected -ge ${#items[@]} ]] && selected=0;;
                esac
            fi
        elif [[ $key == '' ]]; then
            ARROW_SELECTED_ITEM="${items[$selected]}"
            clear_screen
            return 0
        fi
    done
}


# Docker helper (no sudo password storage)
######################################

docker_cmd() {
    if [[ "$USE_SUDO_FOR_DOCKER" -eq 1 ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        show_message "Docker is not installed."
        centered_read "Do you want to install it now? (y/n)"
        local ans="$CENTERED_READ_RESULT"
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo apt-get update -y
            sudo apt-get install -y docker.io
            sudo systemctl start docker
        else
            show_message "Exiting."
            exit 1
        fi
    fi

    if ! systemctl is-active --quiet docker 2>/dev/null; then
        sudo systemctl start docker 2>/dev/null
    fi

    if ! docker info &> /dev/null; then
        if sudo docker info &> /dev/null; then
            USE_SUDO_FOR_DOCKER=1
        else
            show_message "Cannot connect to Docker daemon even with sudo. Exiting."
            exit 1
        fi
    fi
}

get_ubuntu_ip() {
    hostname -I | awk '{print $1}'
}


# Flask auto-fix (host and debug only, no port lock)
######################################

fix_flask_config() {
    local app_file="$1"
    if [[ -f "$app_file" ]] && grep -q 'app\.run(' "$app_file"; then
        sed -i "s/host=['\"]127\.0\.0\.1['\"]/host='0.0.0.0'/g" "$app_file"
        sed -i "s/debug=True/debug=False/g" "$app_file"
        sed -i "s/debug=\"True\"/debug=False/g" "$app_file"
        show_message "Flask configuration fixed: host set to 0.0.0.0, debug set to False"
    fi
}


# Deployment functions
######################################

deploy_static() {
    local folder_path host_port container_name image_name web_server

    centered_read "Enter full path to the website folder:"
    folder_path="$CENTERED_READ_RESULT"

    if [[ ! -d "$folder_path" ]] || [[ ! -f "$folder_path/index.html" ]]; then
        show_message "Error: Folder does not exist or does not contain index.html"
        return
    fi

    centered_read "Enter host port (default 8080):"
    host_port="$CENTERED_READ_RESULT"
    host_port=${host_port:-8080}

    centered_read "Enter container name (default static-site-container):"
    container_name="$CENTERED_READ_RESULT"
    container_name=${container_name:-static-site-container}

    centered_read "Enter image name (default static-site-image):"
    image_name="$CENTERED_READ_RESULT"
    image_name=${image_name:-static-site-image}

    arrow_menu "Web Server Selection" "nginx" "apache"
    web_server="$ARROW_SELECTED_ITEM"
    [[ -z "$web_server" ]] && web_server="nginx"

    local dockerfile_path="$folder_path/Dockerfile"
    if [[ "$web_server" == "apache" ]]; then
        echo -e "FROM httpd:alpine\nCOPY . /usr/local/apache2/htdocs/" > "$dockerfile_path"
    else
        echo -e "FROM nginx:alpine\nCOPY . /usr/share/nginx/html" > "$dockerfile_path"
    fi

    echo "Building image..."
    if ! docker_cmd build -t "$image_name" "$folder_path"; then
        show_message "Error: Failed to build image."
        return
    fi

    echo "Running container..."
    if ! docker_cmd run -d -p "$host_port:80" --name "$container_name" "$image_name"; then
        show_message "Error: Failed to run container."
        return
    fi

    local ip=$(get_ubuntu_ip)
    show_message "Deployment successful!" "Local URL: http://localhost:$host_port" "Network URL: http://$ip:$host_port"
}

deploy_python() {
    local folder_path host_port container_name image_name py_version

    centered_read "Enter full path to the app folder:"
    folder_path="$CENTERED_READ_RESULT"

    if [[ ! -d "$folder_path" ]] || [[ ! -f "$folder_path/app.py" ]]; then
        show_message "Error: Folder does not exist or does not contain app.py"
        return
    fi

    fix_flask_config "$folder_path/app.py"

    centered_read "Enter host port (default 5000):"
    host_port="$CENTERED_READ_RESULT"
    host_port=${host_port:-5000}

    centered_read "Enter container name (default flask-app-container):"
    container_name="$CENTERED_READ_RESULT"
    container_name=${container_name:-flask-app-container}

    centered_read "Enter image name (default flask-app-image):"
    image_name="$CENTERED_READ_RESULT"
    image_name=${image_name:-flask-app-image}

    arrow_menu "Python Version" "3.9" "3.10" "3.11"
    py_version="$ARROW_SELECTED_ITEM"
    [[ -z "$py_version" ]] && py_version="3.9"

    local dockerfile_path="$folder_path/Dockerfile"
    cat <<EOF > "$dockerfile_path"
FROM python:${py_version}-slim
WORKDIR /app
COPY . .
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || pip install flask
CMD ["python", "app.py"]
EOF

    echo "Building image..."
    if ! docker_cmd build -t "$image_name" "$folder_path"; then
        show_message "Error: Failed to build image."
        return
    fi

    echo "Running container..."
    if ! docker_cmd run -d -p "$host_port:5000" --name "$container_name" "$image_name"; then
        show_message "Error: Failed to run container."
        return
    fi

    local ip=$(get_ubuntu_ip)
    show_message "Deployment successful!" "Local URL: http://localhost:$host_port" "Network URL: http://$ip:$host_port"
}


# Management functions
######################################

manage_containers() {
    while true; do
        local containers=$(docker_cmd ps --format "{{.Names}} ({{.Image}})")
        if [[ -z "$containers" ]]; then
            show_message "No running containers."
            return
        fi

        local -a display_items=()
        local -a container_names=()
        while IFS= read -r line; do
            local cname=$(echo "$line" | awk '{print $1}')
            container_names+=("$cname")
            display_items+=("$line")
        done <<< "$containers"
        display_items+=("Back to previous menu")

        arrow_menu "Manage Running Containers" "${display_items[@]}"
        local selected_item="$ARROW_SELECTED_ITEM"

        if [[ "$selected_item" == "Back to previous menu" ]]; then
            return
        fi

        local selected_container=""
        for i in "${!display_items[@]}"; do
            if [[ "${display_items[$i]}" == "$selected_item" ]]; then
                selected_container="${container_names[$i]}"
                break
            fi
        done

        [[ -z "$selected_container" ]] && continue

        while true; do
            clear_screen
            local mapped_port=$(docker_cmd port "$selected_container" | head -n1 | awk -F: '{print $NF}')
            [[ -z "$mapped_port" ]] && mapped_port="unknown"
            local ip=$(get_ubuntu_ip)

            # Display URLs as a centered message? We'll just show above menu.
            # For arrow UI consistency, we can include them in the title or use show_message then menu.
            # Simpler: show a message with URLs, then menu.
            show_message "Local URL: http://localhost:$mapped_port" "Network URL: http://$ip:$mapped_port"

            arrow_menu "Actions for $selected_container" \
                "Show logs" \
                "Test local URL" \
                "Test network URL" \
                "Stop container" \
                "Restart container" \
                "Remove container" \
                "Back to previous menu"
            local action="$ARROW_SELECTED_ITEM"

            case $action in
                "Show logs")
                    docker_cmd logs "$selected_container"
                    bottom_pause
                    ;;
                "Test local URL")
                    if [[ "$mapped_port" == "unknown" ]]; then
                        centered_read "No port mapping found. Enter port:"
                        mapped_port="$CENTERED_READ_RESULT"
                    fi
                    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$mapped_port")
                    if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" || "$http_code" == "404" ]]; then
                        show_message "Local test success! HTTP Code: $http_code"
                    else
                        show_message "Local test failed or error code: $http_code"
                    fi
                    ;;
                "Test network URL")
                    if [[ "$mapped_port" == "unknown" ]]; then
                        centered_read "No port mapping found. Enter port:"
                        mapped_port="$CENTERED_READ_RESULT"
                    fi
                    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://$ip:$mapped_port")
                    if [[ "$http_code" == "200" || "$http_code" == "301" || "$http_code" == "302" || "$http_code" == "404" ]]; then
                        show_message "Network test success! HTTP Code: $http_code"
                    else
                        show_message "Network test failed or error code: $http_code"
                    fi
                    ;;
                "Stop container")
                    centered_read "Stop container $selected_container? (y/n)"
                    local ans="$CENTERED_READ_RESULT"
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        if docker_cmd stop "$selected_container"; then
                            show_message "Container stopped."
                        else
                            show_message "Failed to stop container."
                        fi
                        break
                    fi
                    ;;
                "Restart container")
                    if docker_cmd restart "$selected_container"; then
                        show_message "Container restarted."
                    else
                        show_message "Failed to restart container."
                    fi
                    ;;
                "Remove container")
                    centered_read "Remove container $selected_container? (y/n)"
                    local ans="$CENTERED_READ_RESULT"
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        if docker_cmd rm -f "$selected_container"; then
                            show_message "Container removed."
                        else
                            show_message "Failed to remove container."
                        fi
                        break
                    fi
                    ;;
                "Back to previous menu")
                    break
                    ;;
            esac
        done
    done
}

list_docker_images() {
    while true; do
        local images=$(docker_cmd images --format "{{.Repository}}:{{.Tag}} ID: {{.ID}} Size: {{.Size}}")
        if [[ -z "$images" ]]; then
            show_message "No images found."
            return
        fi

        local -a display_items=()
        local -a img_ids=()
        local -a img_refs=()
        while IFS= read -r line; do
            local iref=$(echo "$line" | awk '{print $1}')
            local iid=$(echo "$line" | awk '{print $3}')
            local isize=$(echo "$line" | awk '{print $5}')
            img_refs+=("$iref")
            img_ids+=("$iid")
            display_items+=("$iref (ID: $iid, Size: $isize)")
        done <<< "$images"
        display_items+=("Back to previous menu")

        arrow_menu "Docker Images List" "${display_items[@]}"
        local selected_item="$ARROW_SELECTED_ITEM"

        if [[ "$selected_item" == "Back to previous menu" ]]; then
            return
        fi

        local selected_id=""
        local selected_ref=""
        for i in "${!display_items[@]}"; do
            if [[ "${display_items[$i]}" == "$selected_item" ]]; then
                selected_id="${img_ids[$i]}"
                selected_ref="${img_refs[$i]}"
                break
            fi
        done

        [[ -z "$selected_id" ]] && continue

        while true; do
            arrow_menu "Actions for Image $selected_ref" \
                "Run container from this image" \
                "Delete this image" \
                "Back to previous menu"
            local img_action="$ARROW_SELECTED_ITEM"

            case $img_action in
                "Run container from this image")
                    centered_read "Enter container name:"
                    local cname="$CENTERED_READ_RESULT"
                    centered_read "Enter host port (e.g., 8080):"
                    local hport="$CENTERED_READ_RESULT"
                    centered_read "Enter container port (default 80):"
                    local cport="$CENTERED_READ_RESULT"
                    cport=${cport:-80}
                    if docker_cmd run -d -p "$hport:$cport" --name "$cname" "$selected_id"; then
                        show_message "Container started."
                    else
                        show_message "Failed to run container."
                    fi
                    ;;
                "Delete this image")
                    centered_read "Delete image $selected_ref? (y/n)"
                    local ans="$CENTERED_READ_RESULT"
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        if docker_cmd rmi "$selected_id"; then
                            show_message "Image deleted."
                        else
                            show_message "Failed to delete image."
                        fi
                        break
                    fi
                    ;;
                "Back to previous menu")
                    break
                    ;;
            esac
        done
    done
}

list_all_containers() {
    while true; do
        local containers=$(docker_cmd ps -a --format "{{.Names}} Image: {{.Image}} Status: {{.Status}}")
        if [[ -z "$containers" ]]; then
            show_message "No containers found."
            return
        fi

        local -a display_items=()
        local -a c_names=()
        while IFS= read -r line; do
            local cname=$(echo "$line" | awk '{print $1}')
            c_names+=("$cname")
            display_items+=("$line")
        done <<< "$containers"
        display_items+=("Back to previous menu")

        arrow_menu "All Containers List" "${display_items[@]}"
        local selected_item="$ARROW_SELECTED_ITEM"

        if [[ "$selected_item" == "Back to previous menu" ]]; then
            return
        fi

        local selected_container=""
        for i in "${!display_items[@]}"; do
            if [[ "${display_items[$i]}" == "$selected_item" ]]; then
                selected_container="${c_names[$i]}"
                break
            fi
        done

        [[ -z "$selected_container" ]] && continue

        while true; do
            arrow_menu "Actions for $selected_container" \
                "Start container" \
                "Stop container" \
                "Show logs" \
                "Remove container" \
                "Back to previous menu"
            local cont_action="$ARROW_SELECTED_ITEM"

            case $cont_action in
                "Start container")
                    if docker_cmd start "$selected_container"; then
                        show_message "Container started."
                    else
                        show_message "Failed to start container."
                    fi
                    ;;
                "Stop container")
                    if docker_cmd stop "$selected_container"; then
                        show_message "Container stopped."
                    else
                        show_message "Failed to stop container."
                    fi
                    ;;
                "Show logs")
                    docker_cmd logs "$selected_container"
                    bottom_pause
                    ;;
                "Remove container")
                    centered_read "Remove container $selected_container? (y/n)"
                    local ans="$CENTERED_READ_RESULT"
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        if docker_cmd rm -f "$selected_container"; then
                            show_message "Container removed."
                        else
                            show_message "Failed to remove container."
                        fi
                        break
                    fi
                    ;;
                "Back to previous menu")
                    break
                    ;;
            esac
        done
    done
}

manage_images_containers() {
    while true; do
        arrow_menu "Manage Images and Containers" \
            "List all containers (including stopped)" \
            "List Docker images" \
            "Back to main menu"
        local choice="$ARROW_SELECTED_ITEM"

        case $choice in
            "List all containers (including stopped)") list_all_containers ;;
            "List Docker images") list_docker_images ;;
            "Back to main menu") return ;;
        esac
    done
}


# Main menu
######################################

main_menu() {
    while true; do
        arrow_menu "The Docker Project" \
            "Deploy static website" \
            "Deploy Python Flask app" \
            "Manage running containers" \
            "Manage images and old containers" \
            "Exit"
        local choice="$ARROW_SELECTED_ITEM"

        case $choice in
            "Deploy static website") deploy_static ;;
            "Deploy Python Flask app") deploy_python ;;
            "Manage running containers") manage_containers ;;
            "Manage images and old containers") manage_images_containers ;;
            "Exit") clear_screen; show_message "Exiting."; exit 0 ;;
        esac
    done
}


# Startup
######################################

check_docker
main_menu