#!/bin/bash

# Configuration Defaults
TORBOX_API_KEY=""
LANGUAGE="en"
NO_ADULT=true
QUALITIES="2160p,1080p,720p,480p"
THREADS=100

YTS_BASE_URL="https://movies-api.accel.li/api/v2/list_movies.json?limit=50"
TORBOX_CHECK_URL="https://api.torbox.app/v1/api/torrents/checkcached"
TORBOX_CREATE_URL="https://api.torbox.app/v1/api/torrents/createtorrent"
IMDB_URL="https://datasets.imdbws.com/title.basics.tsv.gz"

usage() {
    echo "Usage: $0 -a <api_key> [-l <lang>] [-q <qualities>] [--include-porn]"
    echo "Qualities format: 3D,2160p,1080p,720p,480p (comma-separated)"
    exit 1
}

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -a) TORBOX_API_KEY="$2"; shift ;;
        -l) LANGUAGE="$2"; shift ;;
        -q) QUALITIES="$2"; shift ;;
        --include-porn) NO_ADULT=false ;;
        *) usage ;;
    esac
    shift
done

# Validate Qualities
IFS=',' read -ra Q_ARR <<< "$QUALITIES"
for q in "${Q_ARR[@]}"; do
    if [[ ! "$q" =~ ^(3D|2160p|1080p|720p|480p)$ ]]; then
        echo "Error: Invalid quality '$q'."; usage
    fi
done

if [ -z "$TORBOX_API_KEY" ]; then echo "Error: API key required."; usage; fi

TEMP_DIR=$(mktemp -d)
IMDB_FILE="$TEMP_DIR/title.basics.tsv"

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

# --- PHASE 0: Setup ---
if [ "$NO_ADULT" = true ]; then
    echo "Downloading IMDB dataset for filtering..."
    curl -L -o "$TEMP_DIR/title.basics.tsv.gz" "$IMDB_URL" && gunzip -f "$TEMP_DIR/title.basics.tsv.gz"
fi

# --- PHASE 1: YTS Scrape & Priority Scoring  ---
echo "Initializing..."
INIT_URL="${YTS_BASE_URL}&page=1"
[[ "$LANGUAGE" != "all" ]] && INIT_URL="${INIT_URL}&language=$LANGUAGE"

# Calculate total pages
MOVIE_COUNT=$(curl -s "$INIT_URL" | jq -r '.data.movie_count // 0')
TOTAL_PAGES=$(( (MOVIE_COUNT + 49) / 50 ))

echo "Scraping $TOTAL_PAGES pages with $THREADS threads..."

fetch_page() {
    local PAGE=$1
    local OUT_FILE="$TEMP_DIR/page_${PAGE}.json"
    local REQ_URL="${YTS_BASE_URL}&page=$PAGE"
    [[ "$LANGUAGE" != "all" ]] && REQ_URL="${REQ_URL}&language=$LANGUAGE"

    while true; do
        RESPONSE=$(curl -s -w "\n%{http_code}" "$REQ_URL")
        STATUS=$(echo "$RESPONSE" | tail -n1)
        if [ "$STATUS" -eq 429 ]; then sleep 5; continue; fi
        if [ "$STATUS" -ne 200 ]; then echo "Status ${STATUS} for page ${PAGE}. Retrying..."; continue; fi

        echo "$RESPONSE" | sed '$d' | jq -c '.data.movies[]? | {imdb: .imdb_code, torrents: [.torrents[]? | . + {
            score: ((if .video_codec == "x265" then 2 else 1 end) + (if .type == "bluray" then 2 else 1 end)),
            is3d: (.quality == "3D")
        }]}' > "$OUT_FILE"
        break
    done
}

for PAGE in $(seq 1 $TOTAL_PAGES); do
    while [ $(jobs -rp | wc -l) -ge "$THREADS" ]; do sleep 0.05; done
    fetch_page "$PAGE" &
    DONE=$(ls -1 "$TEMP_DIR"/page_*.json 2>/dev/null | wc -l)
    printf "\rScraping: [%-40s] %d/%d" "$(printf '#%.0s' $(seq 1 $((DONE * 40 / TOTAL_PAGES))))" "$DONE" "$TOTAL_PAGES"
done

wait
echo -e "\nApplying priority logic (Qualities: $QUALITIES)..."

jq -r --arg Q "$QUALITIES" '
    def has_q(val): ($Q | split(",")) | contains([val]);
    (if .data and .data.movies then .data.movies[] else . end) | 
    select(type == "object" and .torrents != null and (.torrents | type) == "array") |
    .torrents | 
    (if has_q("3D") then (map(select(.quality == "3D")) | sort_by(.score) | last) else null end) as $b3d |
    (if has_q("2160p") then (map(select(.quality == "2160p")) | sort_by(.score) | last) else null end) as $b4k |
    (if has_q("1080p") then (map(select(.quality == "1080p")) | sort_by(.score) | last) else null end) as $b1080 |
    (if (has_q("720p") or has_q("480p")) then 
        (if ($b4k == null and $b1080 == null) then (map(select(.quality == "720p" or .quality == "480p")) | sort_by(.score) | last) else null end) 
     else null end) as $bSD |
    [$b3d, $b4k, $b1080, $bSD] | map(select(. != null)) | first | .hash // empty
' "$TEMP_DIR"/page_*.json | sort -u > "$TEMP_DIR/selected_torrents.txt"

echo "Selection complete. Found $(wc -l < "$TEMP_DIR/selected_torrents.txt" | tr -d ' ') unique torrents."

# --- PHASE 2: Adult Filtering ---
if [ "$NO_ADULT" = true ]; then
    echo "Filtering adult content..."

    cat "$TEMP_DIR"/page_*.json | jq -r '.imdb + "," + (.torrents[].hash)' > "$TEMP_DIR/hash_to_imdb_map.txt"

    awk -F'\t' 'NR==FNR { adult_imdb_set[$1]; next } 
                $5=="1" && ($1 in adult_imdb_set)' \
        <(awk -F',' 'NR==FNR{hashes[$1]; next} ($2 in hashes) {print $1}' "$TEMP_DIR/selected_torrents.txt" "$TEMP_DIR/hash_to_imdb_map.txt" | sort -u) \
        "$IMDB_FILE" > "$TEMP_DIR/adult_imdb_ids.txt"

    awk -F',' 'NR==FNR { adult_ids[$1]; next } !($1 in adult_ids) { print $2 }' \
    "$TEMP_DIR/adult_imdb_ids.txt" \
    "$TEMP_DIR/hash_to_imdb_map.txt" > "$TEMP_DIR/filtered_torrents.txt"

    mv "$TEMP_DIR/filtered_torrents.txt" "$TEMP_DIR/selected_torrents.txt"
fi

# --- PHASE 3: Exclude Already Owned Torrents ---
echo "Fetching your existing TorBox library to prevent duplicates..."
touch "$TEMP_DIR/existing_torrents.txt"
MYLIST_OFFSET=0
MYLIST_LIMIT=10000

while true; do
    RES=$(curl -s -w "\n%{http_code}" -X GET "https://api.torbox.app/v1/api/torrents/mylist?limit=$MYLIST_LIMIT&offset=$MYLIST_OFFSET" \
        -H "Authorization: Bearer $TORBOX_API_KEY")
    
    STATUS=$(echo "$RES" | tail -n1)
    BODY=$(echo "$RES" | sed '$d')
    
    if [ "$STATUS" -eq 429 ]; then
        echo -e "\nRate limited. Waiting 15s..."
        sleep 15
        continue
    elif [[ "$STATUS" =~ ^50[0-4]$ ]]; then
        echo -e "\nServer overloaded ($STATUS). Waiting 15s..."
        sleep 15
        continue
    elif [ "$STATUS" -ne 200 ]; then
        echo -e "\nWarning: Failed to fetch mylist (Status: $STATUS). Proceeding without duplicate check."
        break
    fi
    
    DATA_LENGTH=$(echo "$BODY" | jq '.data | length // 0')
    if [ "$DATA_LENGTH" -eq 0 ]; then
        break 
    fi
    
    echo "$BODY" | jq -r '.data[]? | select(.download_state == "cached") | .hash // empty' >> "$TEMP_DIR/existing_torrents.txt"
    
    MYLIST_OFFSET=$(( MYLIST_OFFSET + MYLIST_LIMIT ))
    printf "\rFetched %d items from your library..." "$MYLIST_OFFSET"
done

EXISTING_COUNT=$(wc -l < "$TEMP_DIR/existing_torrents.txt" | tr -d ' ')
echo -e "\nFound $EXISTING_COUNT successfully cached torrents in your account."

awk 'NR==FNR{seen[$1]; next} !($1 in seen)' "$TEMP_DIR/existing_torrents.txt" "$TEMP_DIR/selected_torrents.txt" > "$TEMP_DIR/new_selected_torrents.txt"
mv "$TEMP_DIR/new_selected_torrents.txt" "$TEMP_DIR/selected_torrents.txt"

echo "Remaining new torrents to process: $(wc -l < "$TEMP_DIR/selected_torrents.txt" | tr -d ' ')"

# --- PHASE 4: Torbox Cache Check (Dynamic Batching) ---
# Calculate maximum safe hashes per batch based on OS ARG_MAX limit
OS_ARG_MAX=$(getconf ARG_MAX 2>/dev/null || echo 2097152)
SAFE_ARG_MAX=$(( OS_ARG_MAX * 9 / 10 ))
CURRENT_BATCH_SIZE=$(( SAFE_ARG_MAX / 50 ))

# Cap at 10,000 to prevent API payload/timeout errors based on server limits
if [ "$CURRENT_BATCH_SIZE" -gt 10000 ]; then CURRENT_BATCH_SIZE=10000; fi

TOTAL_HASHES=$(wc -l < "$TEMP_DIR/selected_torrents.txt" | tr -d ' ')
CURRENT_OFFSET=0
touch "$TEMP_DIR/raw_cached_hashes.txt"

echo "Starting dynamic cache check. Max batch size: $CURRENT_BATCH_SIZE..."

# Loop dynamically through the list using offset logic
while [ "$CURRENT_OFFSET" -lt "$TOTAL_HASHES" ]; do
    REMAINING=$(( TOTAL_HASHES - CURRENT_OFFSET ))
    GRAB_COUNT=$(( CURRENT_BATCH_SIZE < REMAINING ? CURRENT_BATCH_SIZE : REMAINING ))
    
    # Extract the exact block of hashes for this attempt
    tail -n +$(( CURRENT_OFFSET + 1 )) "$TEMP_DIR/selected_torrents.txt" | head -n "$GRAB_COUNT" > "$TEMP_DIR/current_batch.txt"
    
    jq -R . < "$TEMP_DIR/current_batch.txt" | jq -s '{hashes: .}' > "$TEMP_DIR/current_payload.json"
    
    RES=$(curl -s -w "\n%{http_code}" -X POST "$TORBOX_CHECK_URL" \
        -H "Authorization: Bearer $TORBOX_API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$TEMP_DIR/current_payload.json")
        
    STATUS=$(echo "$RES" | tail -n1)
    
    if [ "$STATUS" -eq 429 ]; then
        echo -e "\nRate limited (429). Waiting 15s..."
        sleep 15
        continue
    elif [[ "$STATUS" =~ ^50[0-4]$ ]] || [ "$STATUS" -eq 413 ] || [ "$STATUS" -eq 400 ]; then
        # Handle 5xx errors or Payload Too Large by halving the batch size
        NEW_BATCH=$(( CURRENT_BATCH_SIZE / 2 ))
        if [ "$NEW_BATCH" -lt 50 ]; then
            echo -e "\nFatal: Server keeps rejecting even small batches (Status: $STATUS). Response:"
            echo "$RES" | sed '$d'
            break
        fi
        echo -e "\nServer returned $STATUS. Dropping batch size from $CURRENT_BATCH_SIZE to $NEW_BATCH..."
        CURRENT_BATCH_SIZE=$NEW_BATCH
        sleep 5
        continue # Retries the loop without increasing CURRENT_OFFSET
    elif [ "$STATUS" -ne 200 ]; then
        echo -e "\nFatal Error: API returned status $STATUS"
        break
    fi
    
    # Success: Save output and advance the offset
    echo "$RES" | sed '$d' | jq -r '.data | keys[]?' >> "$TEMP_DIR/raw_cached_hashes.txt"
    CURRENT_OFFSET=$(( CURRENT_OFFSET + GRAB_COUNT ))
    printf "\rCache Check: %d/%d (Current Batch Size: %d)   " "$CURRENT_OFFSET" "$TOTAL_HASHES" "$CURRENT_BATCH_SIZE"
done
echo ""

# --- PHASE 5: Add to TorBox ---
CACHED_HASHES=$(wc -l < "$TEMP_DIR/raw_cached_hashes.txt" | tr -d ' ')
echo "Adding $CACHED_HASHES new cached torrents to TorBox..."
COUNTER=0

while IFS= read -r HASH; do
    [ -z "$HASH" ] && continue
    ((COUNTER++))
    while true; do
        RES=$(curl -s -w "\n%{http_code}" -X POST "$TORBOX_CREATE_URL" \
            -H "Authorization: Bearer $TORBOX_API_KEY" \
            -F "magnet=magnet:?xt=urn:btih:$HASH")
            
        STATUS=$(echo "$RES" | tail -n1)
        
        if [ "$STATUS" -eq 429 ]; then 
            sleep 15
            continue
        fi
        break
    done
    printf "\rAdding: %d/%d" "$COUNTER" "$CACHED_HASHES"
    sleep 0.25 # Small delay to respect baseline limits
done < "$TEMP_DIR/raw_cached_hashes.txt"

echo -e "\nProcess complete."
