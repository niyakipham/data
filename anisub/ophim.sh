#!/bin/bash

play_anime() {

    # Hàm chọn anime dựa trên từ khóa tìm kiếm
    select_anime() {
        local keyword="$1"
        local anime_list

        # Tìm kiếm anime trên ophim17.cc, lấy link và tiêu đề
        anime_list=$(
            curl -s "https://ophim17.cc/tim-kiem?keyword=$keyword" |
            pup '.ml-4 > a attr{href}' | # Trích xuất href từ các thẻ a trong div có class ml-4
            awk '{print "https://ophim17.cc" $0}' | # Thêm domain vào link tương đối
            while IFS= read -r link; do
                # Lấy tiêu đề từ trang chi tiết của anime
                title=$(curl -s "$link" | pup 'h1 text{}')
                # In ra định dạng link@@@title
                printf '%s\n' "$link@@@$title"
            done |
            # Định dạng lại thành "STT. Tiêu đề (link)"
            awk -F '@@@' '{print NR ". " $2 " (" $1 ")"}'
        )

        # Kiểm tra nếu không tìm thấy anime
        if [[ -z "$anime_list" ]] || [[ "$anime_list" == "Not Found" ]]; then
            echo "Không tìm thấy anime nào với từ khóa '$keyword'."
            return 1
        fi

        # Sử dụng fzf để người dùng chọn anime
        selected_anime=$(echo "$anime_list" | fzf --prompt="Chọn anime: ")
        # Kiểm tra nếu người dùng không chọn
        if [[ -z "$selected_anime" ]]; then
            echo "Không có anime nào được chọn."
            return 1
        fi

        # Trả về link của anime đã chọn
        echo "$selected_anime" | sed 's/.*(\(.*\))/\1/'
    }

    # Hàm lấy danh sách link m3u8 các tập từ URL trang anime
    get_episode_list_from_url() {
        local url="$1"
        local html_content
        local episode_data

        # Tải nội dung HTML của trang anime
        html_content=$(curl -s "$url")
        if [[ -z "$html_content" ]]; then
            echo "Không thể tải nội dung từ URL: $url" >&2
            return 1
        fi

        # Trích xuất các link m3u8 từ dữ liệu JSON trong thẻ script
        # Sử dụng pup để lấy JSON, jq để parse và grep để lọc link m3u8
        episode_data=$(echo "$html_content" | pup 'script json{}' | jq -r '.[].text | @text' | grep -oE '"(http|https)://[^"]*index.m3u8"' | sed 's/"//g')

        # Kiểm tra nếu không tìm thấy link tập phim
        if [[ -z "$episode_data" ]]; then
            echo "Không tìm thấy danh sách tập phim cho URL: $url" >&2
            return 1
        fi

        # Đánh số thứ tự cho các link tập phim
        local i=1
        while IFS= read -r link; do
            printf "%s|%s\n" "$i" "$link" # Định dạng: số_tập|link_m3u8
            i=$((i + 1))
        done <<< "$episode_data"
    }

    # Hàm gọi get_episode_list_from_url (có thể mở rộng sau này)
    get_episode_list() {
        get_episode_list_from_url "$1"
    }

    # Hàm lấy tiêu đề tập phim (hiện tại chưa dùng hiệu quả do cấu trúc web thay đổi)
    get_episode_title() {
        local episode_url="$1" # URL trang anime, không phải link m3u8
        local episode_number="$2"
        local episode_title

        # Thử lấy tên tập từ trang anime (cần kiểm tra lại selector CSS)
        # episode_title=$(curl -s "$episode_url" | pup ".ep-name text{}" | sed -n "${episode_number}p") # Selector này có thể không còn đúng

        # Nếu không lấy được, dùng tên mặc định
        if [[ -z "$episode_title" ]]; then
            episode_title="Episode $episode_number"
        fi

        echo "$episode_title"
    }

    # Hàm chính để phát video sau khi đã chọn anime
    play_video() {
        local selected_anime_url="$1" # Nhận URL trực tiếp từ select_anime
        local episode_data
        local anime_name

        # Lấy tên anime từ URL (phần cuối cùng của path)
        anime_name=$(echo "$selected_anime_url" | awk -F'/' '{print $NF}')

        # Lấy danh sách tập phim
        episode_data=$(get_episode_list "$selected_anime_url")
        if [[ -z "$episode_data" ]]; then
            echo "Không tìm thấy danh sách tập phim." >&2
            return 1
        fi

        # Gọi hàm hiển thị menu và phát video
        # Truyền tên anime và URL vào play_video_with_menu
        play_video_with_menu "$anime_name ($selected_anime_url)" "$selected_anime_url" "$episode_data" "$anime_name"
    }

    # Hàm hiển thị menu điều khiển khi đang phát video
    play_video_with_menu() {
        local selected_anime_display="$1" # Chuỗi hiển thị tên và URL anime
        local anime_url="$2"
        local episode_data="$3"
        local anime_name="$4" # Chỉ tên anime
        local selected_episode
        local current_episode_number
        local current_link
        local action
        local next_episode_number
        local next_link
        local previous_episode_number
        local previous_link
        local episode_title
        local mpv_pid
        local download_status=""
        local anime_dir

        # Sử dụng fzf để chọn tập phim ban đầu
        selected_episode=$(echo "$episode_data" | fzf --prompt="Chọn tập phim cho '$anime_name': " --preview 'echo Tập $(echo {} | cut -d"|" -f1)')
        if [[ -z "$selected_episode" ]]; then
            echo "Không có tập nào được chọn." >&2
            return 1
        fi

        # Lấy số tập và link m3u8 của tập đã chọn
        current_episode_number=$(echo "$selected_episode" | cut -d'|' -f1)
        current_link=$(echo "$selected_episode" | cut -d'|' -f2)

        # Vòng lặp chính để phát và điều khiển video
        while true; do
            echo "Đang chuẩn bị phát tập $current_episode_number..."
            # Phát video bằng mpv trong nền
            mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
            mpv_pid=$! # Lấy PID của tiến trình mpv

            # Vòng lặp kiểm tra mpv còn chạy và hiển thị menu fzf
            while kill -0 "$mpv_pid" 2> /dev/null; do
                # Hiển thị menu fzf để điều khiển
                action=$(echo -e "Next\nPrevious\nSelect\nDownloads\nCut Video\nGrafting" | fzf --prompt="Đang phát: Tập $current_episode_number $download_status - '$anime_name': ")

                # Reset trạng thái download
                download_status=""

                case "$action" in
                "Next")
                    kill "$mpv_pid" # Dừng mpv hiện tại
                    # Tìm tập tiếp theo
                    next_episode_number=$((current_episode_number + 1))
                    next_link=$(echo "$episode_data" | grep "^$next_episode_number|" | cut -d'|' -f2)
                    if [[ -z "$next_link" ]]; then
                        echo "Không có tập tiếp theo." >&2
                        # Nếu không có tập tiếp, giữ nguyên tập hiện tại và khởi động lại mpv (hoặc không làm gì cả)
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    else
                        # Cập nhật tập hiện tại và phát tập tiếp theo
                        current_episode_number=$next_episode_number
                        current_link=$next_link
                        echo "Đang phát tập $current_episode_number..."
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    fi
                    ;;
                "Previous")
                    kill "$mpv_pid" # Dừng mpv hiện tại
                    # Tìm tập trước đó
                    previous_episode_number=$((current_episode_number - 1))
                    previous_link=$(echo "$episode_data" | grep "^$previous_episode_number|" | cut -d'|' -f2)
                    if [[ -z "$previous_link" || "$previous_episode_number" -lt 1 ]]; then
                        echo "Không có tập trước đó." >&2
                        # Nếu không có tập trước, giữ nguyên tập hiện tại và khởi động lại mpv
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    else
                        # Cập nhật tập hiện tại và phát tập trước đó
                        current_episode_number=$previous_episode_number
                        current_link=$previous_link
                        echo "Đang phát tập $current_episode_number..."
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    fi
                    ;;
                "Select")
                    kill "$mpv_pid" # Dừng mpv hiện tại
                    # Cho phép chọn lại tập khác
                    selected_episode=$(echo "$episode_data" | fzf --prompt="Chọn tập phim cho '$anime_name': " --preview 'echo Tập $(echo {} | cut -d"|" -f1)')
                    if [[ -z "$selected_episode" ]]; then
                        echo "Không có tập nào được chọn. Phát lại tập hiện tại." >&2
                        # Nếu không chọn, phát lại tập cũ
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    else
                        # Cập nhật tập hiện tại và phát tập mới chọn
                        current_episode_number=$(echo "$selected_episode" | cut -d'|' -f1)
                        current_link=$(echo "$selected_episode" | cut -d'|' -f2)
                        echo "Đang phát tập $current_episode_number..."
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                    fi
                    ;;
                "Downloads")
                    kill "$mpv_pid" # Dừng mpv để tải

                    # Tạo thư mục lưu trữ dựa trên tên anime (lấy từ URL)
                    anime_dir=$(echo "$anime_url" | awk -F'/' '{print $NF}')
                    # Lấy tiêu đề tập phim (sử dụng tên mặc định nếu cần)
                    episode_title=$(get_episode_title "$anime_url" "$current_episode_number") # Hàm này cần URL trang anime
                    # Chuẩn hóa tên file (thay thế ký tự không hợp lệ)
                    safe_episode_title=$(echo "$episode_title" | sed 's/[ /]/_/g; s/[^a-zA-Z0-9_.-]//g')
                    download_dir="$HOME/Downloads/anime/$anime_dir"
                    output_path="$download_dir/${safe_episode_title}_Ep${current_episode_number}.%(ext)s"

                    # Tạo thư mục nếu chưa tồn tại
                    mkdir -p "$download_dir"

                    download_status="(Đang tải...)" # Cập nhật trạng thái trên fzf prompt
                    echo "Đang tải tập $current_episode_number - $episode_title vào thư mục $anime_dir..."
                    # Sử dụng yt-dlp để tải
                    if yt-dlp -o "$output_path" "$current_link"; then
                        download_status="(Đã tải xong)"
                        echo "Đã tải xong: $output_path"
                    else
                        download_status="(Tải lỗi)"
                        echo "Tải tập $current_episode_number thất bại." >&2
                    fi

                    # Phát lại video sau khi tải xong hoặc lỗi
                    mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                    mpv_pid=$!
                    ;;
                "Cut Video")
                    kill "$mpv_pid" # Dừng mpv để cắt

                    # Kiểm tra yt-dlp
                    if ! command -v yt-dlp &> /dev/null; then
                        echo "yt-dlp không được tìm thấy. Vui lòng cài đặt." >&2
                        # Phát lại video nếu không có yt-dlp
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                        continue # Quay lại vòng lặp fzf
                    fi

                    # Chọn chế độ cắt
                    cut_option=$(echo -e "Cắt 1 lần\nCắt nhiều lần" | fzf --prompt="Chọn chế độ cắt: ")
                    cut_dir="$HOME/Downloads/anime/cut"
                    mkdir -p "$cut_dir" # Tạo thư mục cut nếu chưa có

                    case "$cut_option" in
                        "Cắt 1 lần")
                            read -r -p "Nhập thời gian bắt đầu (HH:MM:SS hoặc giây): " start_time
                            read -r -p "Nhập thời gian kết thúc (HH:MM:SS hoặc giây): " end_time
                            output_file="$cut_dir/cut_${anime_name}_Ep${current_episode_number}_$(date +%s).mp4"
                            echo "Đang cắt video từ $start_time đến $end_time..."
                            # Sử dụng --download-sections của yt-dlp
                            if yt-dlp --download-sections "*${start_time}-${end_time}" -o "$output_file" "$current_link"; then
                                echo "Video đã được cắt và lưu tại: $output_file"
                            else
                                echo "Cắt video thất bại." >&2
                            fi
                            ;;
                        "Cắt nhiều lần")
                            read -r -p "Nhập số lượng phân đoạn muốn cắt: " num_segments
                            for ((i=1; i<=num_segments; i++)); do
                                echo "--- Phân đoạn $i ---"
                                read -r -p "Nhập thời gian bắt đầu (HH:MM:SS hoặc giây): " start_time
                                read -r -p "Nhập thời gian kết thúc (HH:MM:SS hoặc giây): " end_time
                                output_file="$cut_dir/cut_${anime_name}_Ep${current_episode_number}_${i}_$(date +%s).mp4"
                                echo "Đang cắt phân đoạn $i từ $start_time đến $end_time..."
                                if yt-dlp --download-sections "*${start_time}-${end_time}" -o "$output_file" "$current_link"; then
                                     echo "Phân đoạn $i đã được cắt và lưu tại: $output_file"
                                else
                                     echo "Cắt phân đoạn $i thất bại." >&2
                                fi
                            done
                            ;;
                        *)
                            echo "Lựa chọn không hợp lệ." >&2
                            ;;
                    esac
                    # Phát lại video sau khi cắt
                    mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                    mpv_pid=$!
                    ;;
                "Grafting")
                    kill "$mpv_pid" # Dừng mpv để ghép

                    # Kiểm tra ffmpeg
                    if ! command -v ffmpeg &> /dev/null; then
                        echo "ffmpeg không được tìm thấy. Vui lòng cài đặt." >&2
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                        continue
                    fi

                    cut_dir="$HOME/Downloads/anime/cut"
                    graft_dir="$HOME/Downloads/anime/grafting"
                    mkdir -p "$graft_dir" # Tạo thư mục grafting nếu chưa có

                    # Kiểm tra xem có file nào trong thư mục cut không
                    if ! find "$cut_dir" -maxdepth 1 -name '*.mp4' -print -quit | grep -q .; then
                        echo "Không tìm thấy video nào trong thư mục '$cut_dir' để ghép." >&2
                        mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                        mpv_pid=$!
                        continue
                    fi


                    grafting_option=$(echo -e "Ghép 1 lần\nGhép nhiều lần" | fzf --prompt="Chọn chế độ ghép: ")

                    case "$grafting_option" in
                        "Ghép 1 lần")
                            read -r -p "Bạn muốn ghép bao nhiêu video lại với nhau: " num_videos
                            video_files=()
                            input_list_file=$(mktemp) # Tạo file tạm để chứa danh sách video

                            echo "Chọn các video để ghép:"
                            for ((i=1; i<=num_videos; i++)); do
                                # Sử dụng fzf để chọn file, cho phép chọn nhiều file với --multi
                                selected_file=$(find "$cut_dir" -maxdepth 1 -type f -name "*.mp4" | fzf --prompt="Chọn video $i (trong $num_videos): ")
                                if [[ -n "$selected_file" ]]; then
                                    video_files+=("$selected_file")
                                    echo "file '$selected_file'" >> "$input_list_file" # Ghi vào file list cho ffmpeg
                                else
                                    echo "Bỏ qua lựa chọn video $i."
                                fi
                            done

                            if [[ ${#video_files[@]} -lt 2 ]]; then
                                echo "Cần ít nhất 2 video để ghép." >&2
                                rm "$input_list_file" # Xóa file tạm
                            else
                                output_file="$graft_dir/grafted_$(date +%s).mp4"
                                echo "Đang ghép ${#video_files[@]} video..."
                                # Sử dụng file list với ffmpeg
                                if ffmpeg -f concat -safe 0 -i "$input_list_file" -c copy "$output_file"; then
                                    echo "Video đã được ghép và lưu tại: $output_file"
                                else
                                    echo "Ghép video thất bại." >&2
                                fi
                                rm "$input_list_file" # Xóa file tạm
                            fi
                            ;;
                        "Ghép nhiều lần")
                            read -r -p "Bạn muốn tạo bao nhiêu vòng lặp ghép: " num_loops
                            for ((loop=1; loop<=num_loops; loop++)); do
                                echo "--- Vòng lặp ghép thứ $loop ---"
                                read -r -p "Bạn muốn ghép bao nhiêu video lại với nhau: " num_videos
                                video_files=()
                                input_list_file=$(mktemp)

                                echo "Chọn các video cho vòng lặp $loop:"
                                for ((i=1; i<=num_videos; i++)); do
                                     selected_file=$(find "$cut_dir" -maxdepth 1 -type f -name "*.mp4" | fzf --prompt="Vòng $loop - Chọn video $i (trong $num_videos): ")
                                     if [[ -n "$selected_file" ]]; then
                                         video_files+=("$selected_file")
                                         echo "file '$selected_file'" >> "$input_list_file"
                                     else
                                         echo "Bỏ qua lựa chọn video $i."
                                     fi
                                done

                                if [[ ${#video_files[@]} -lt 2 ]]; then
                                    echo "Cần ít nhất 2 video để ghép cho vòng lặp $loop. Bỏ qua." >&2
                                    rm "$input_list_file"
                                else
                                    output_file="$graft_dir/grafted_loop${loop}_$(date +%s).mp4"
                                    echo "Đang ghép ${#video_files[@]} video cho vòng lặp $loop..."
                                    if ffmpeg -f concat -safe 0 -i "$input_list_file" -c copy "$output_file"; then
                                        echo "Video vòng lặp $loop đã được ghép và lưu tại: $output_file"
                                    else
                                        echo "Ghép video vòng lặp $loop thất bại." >&2
                                    fi
                                    rm "$input_list_file"
                                fi
                            done
                            ;;
                        *)
                            echo "Lựa chọn không hợp lệ." >&2
                            ;;
                    esac
                    # Phát lại video sau khi ghép
                    mpv "$current_link" --no-terminal --profile=sw-fast --audio-display=no --no-keepaspect-window &
                    mpv_pid=$!
                    ;;
                "") # Người dùng nhấn Enter hoặc Esc trong fzf
                    kill "$mpv_pid" # Dừng mpv
                    echo "Đã dừng phát."
                    # Quyết định xem nên thoát hoàn toàn hay quay lại chọn anime/tập
                    # Hiện tại sẽ thoát script
                    exit 0
                    ;;
                *) # Các lựa chọn không mong muốn khác
                    echo "Lựa chọn không hợp lệ." >&2
                    # Không dừng mpv, chỉ hiển thị lại fzf
                    ;;
                esac
            done # Kết thúc vòng lặp while kill -0 (khi mpv tự kết thúc hoặc bị kill)

            # Kiểm tra xem mpv kết thúc do người dùng chọn hành động hay tự kết thúc
            # Nếu mpv_pid không còn tồn tại và action không phải là Next, Previous, Select, Downloads, Cut, Grafting, ""
            # thì có thể là mpv đã phát xong tập phim.
            # Tuy nhiên, logic hiện tại xử lý trong case "" hoặc các action khác đã kill mpv.
            # Nếu muốn tự động chuyển tập khi hết phim, cần logic phức tạp hơn để theo dõi trạng thái mpv.
            # Hiện tại, sau khi mpv kết thúc (tự nhiên hoặc bị kill), vòng lặp while kill -0 sẽ dừng,
            # và vòng lặp while true bên ngoài sẽ bắt đầu lại, phát lại tập hiện tại (trừ khi action đã thay đổi nó).
            # Để tránh vòng lặp vô hạn nếu mpv lỗi ngay lập tức, có thể thêm điều kiện kiểm tra.
            # Nếu action rỗng (người dùng thoát fzf), script sẽ exit theo logic trong case "".
            # Nếu action là Next/Previous/Select, nó sẽ phát tập mới.
            # Nếu action là Download/Cut/Graft, nó sẽ phát lại tập hiện tại sau khi hoàn thành.
            # Nếu mpv tự kết thúc (ví dụ hết video), vòng lặp while kill -0 dừng, vòng lặp while true bên ngoài
            # sẽ chạy lại, và mpv sẽ được khởi động lại với cùng current_link.
            # Có thể thêm lựa chọn "Quit" vào menu fzf để thoát rõ ràng hơn.

            # Nếu muốn thoát hoàn toàn khi mpv tự kết thúc, thêm kiểm tra ở đây:
            if ! kill -0 "$mpv_pid" 2>/dev/null && [[ -z "$action" ]]; then
                 echo "Video đã kết thúc hoặc bị đóng."
                 # Có thể thêm lựa chọn tự động chuyển tập ở đây nếu muốn
                 # Ví dụ: action="Next"; continue; # Thử chuyển tập tiếp theo
                 break # Thoát khỏi vòng lặp while true để kết thúc script
            fi


        done # Kết thúc vòng lặp while true
    }

    # Hàm xử lý khi người dùng nhập trực tiếp URL
    play_video_from_url() {
        local url="$1"
        local episode_data
        local anime_name

        # Lấy danh sách tập phim từ URL
        episode_data=$(get_episode_list_from_url "$url")
        if [[ -z "$episode_data" ]]; then
            echo "Không tìm thấy danh sách tập phim từ URL." >&2
            return 1
        fi

        # Lấy tên anime từ URL
        anime_name=$(echo "$url" | awk -F'/' '{print $NF}') # Lấy phần cuối path làm tên
        # Tạo chuỗi hiển thị
        selected_anime_display="$anime_name ($url)"

        # Gọi hàm phát video với menu
        play_video_with_menu "$selected_anime_display" "$url" "$episode_data" "$anime_name"
    }


    # ----- Bắt đầu thực thi chính của play_anime -----

    # Vòng lặp yêu cầu nhập liệu cho đến khi có input
    while true; do
        echo -n "Tìm kiếm anime hoặc nhập URL: " # Prompt rõ ràng hơn
        read -r input
        if [[ -z "$input" ]]; then
            echo "Vui lòng nhập từ khóa tìm kiếm hoặc URL."
        else
            break # Thoát vòng lặp khi có input
        fi
    done

    # Kiểm tra xem input là URL hay từ khóa tìm kiếm
    if [[ "$input" =~ ^https?:// ]]; then
        # Nếu là URL, gọi hàm phát từ URL
        play_video_from_url "$input"
    else
        # Nếu là từ khóa, mã hóa và tìm kiếm
        anime_name_encoded=$(echo "$input" | sed 's/ /+/g') # Thay dấu cách bằng dấu + cho URL query
        selected_anime_url=$(select_anime "$anime_name_encoded")

        # Kiểm tra kết quả từ select_anime
        if [[ $? -ne 0 ]] || [[ -z "$selected_anime_url" ]]; then
            # Nếu select_anime trả về lỗi hoặc không có URL, thoát script
             echo "Quá trình chọn anime bị hủy hoặc thất bại."
             exit 1
        fi
        # Nếu chọn thành công, gọi hàm phát video với URL đã chọn
        play_video "$selected_anime_url"
    fi

    # Kết thúc hàm play_anime
}

# Gọi hàm chính để bắt đầu script
play_anime
