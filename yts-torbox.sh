#!/bin/bash

# Configuration Defaults
TORBOX_API_KEY=""
LANGUAGE="en"
NO_ADULT=true
QUALITIES="2160p,1080p,720p,480p"
THREADS=100
BATCH_SIZE=2500 # ARG_MAX limitation (<128 Bytes to support any OS)

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
# trap cleanup EXIT

# --- PHASE 0: Setup ---
if [ "$NO_ADULT" = true ]; then
    echo "Downloading IMDB dataset for filtering..."
    curl -L -o "$TEMP_DIR/title.basics.tsv.gz" "$IMDB_URL" && gunzip "$TEMP_DIR/title.basics.tsv.gz"
fi

# --- PHASE 1: YTS Scrape & Priority Scoring  ---
# Scrapes all hashes from the YTS API
# Scores the quality based on the logic x265>x264, BluRay>Web
echo "Initializing..."
INIT_URL="${YTS_BASE_URL}&page=1"
[[ "$LANGUAGE" != "all" ]] && INIT_URL="${INIT_URL}&language=$LANGUAGE"

# Calculate total pages
MOVIE_COUNT=$(curl -s "$INIT_URL" | jq -r '.data.movie_count // 0')
TOTAL_PAGES=$(( (MOVIE_COUNT + 49) / 50 ))

echo "Scraping $TOTAL_PAGES pages with $THREADS threads..."

# Fetch a single page, with error handling (429 and non 200 codes)
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

        # Score based on priority logic (bluray>web, x265>x264)
        echo "$RESPONSE" | sed '$d' | jq -c '.data.movies[]? | {imdb: .imdb_code, torrents: [.torrents[]? | . + {
            score: ((if .video_codec == "x265" then 2 else 1 end) + (if .type == "bluray" then 2 else 1 end)),
            is3d: (.quality == "3D")
        }]}' > "$OUT_FILE"
        break
    done
}

# Fetch all pages with multi threading
for PAGE in $(seq 1 $TOTAL_PAGES); do
    while [ $(jobs -rp | wc -l) -ge "$THREADS" ]; do sleep 0.05; done
    fetch_page "$PAGE" &
    DONE=$(ls -1 "$TEMP_DIR"/page_*.json 2>/dev/null | wc -l)
    printf "\rScraping: [%-40s] %d/%d" "$(printf '#%.0s' $(seq 1 $((DONE * 40 / TOTAL_PAGES))))" "$DONE" "$TOTAL_PAGES"
done

wait
echo "Applying priority logic (Qualities: $QUALITIES)..."

# Process all scraped JSON files. 
# This handles the extraction, validation, quality sorting, and fallback logic 
# in a single, error-resistant pass without needing 'cat' or 'group_by'.
jq -r --arg Q "$QUALITIES" '
    def has_q(val): ($Q | split(",")) | contains([val]);
    
    # 1. Smart extractor: Handles both YTS API wrapper and direct object format
    (if .data and .data.movies then .data.movies[] else . end) | 
    
    # 2. Strict guardrail: Only proceed if we have a valid torrents array
    select(type == "object" and .torrents != null and (.torrents | type) == "array") |
    
    # 3. Enter the array and sort into our quality buckets
    .torrents | 
    (if has_q("3D") then (map(select(.quality == "3D")) | sort_by(.score) | last) else null end) as $b3d |
    (if has_q("2160p") then (map(select(.quality == "2160p")) | sort_by(.score) | last) else null end) as $b4k |
    (if has_q("1080p") then (map(select(.quality == "1080p")) | sort_by(.score) | last) else null end) as $b1080 |
    (if (has_q("720p") or has_q("480p")) then 
        (if ($b4k == null and $b1080 == null) then (map(select(.quality == "720p" or .quality == "480p")) | sort_by(.score) | last) else null end) 
     else null end) as $bSD |
     
    # 4. Pick the highest priority bucket that has a result and output the hash
    [$b3d, $b4k, $b1080, $bSD] | map(select(. != null)) | first | .hash // empty
' "$TEMP_DIR"/page_*.json | sort -u > "$TEMP_DIR/selected_torrents.txt"

echo "Selection complete. Found $(wc -l < "$TEMP_DIR/selected_torrents.txt") unique torrents."
# --- PHASE 2: Adult Filtering ---
# Uses IMDB 'adult' identifer to filter out porn / gore.
if [ "$NO_ADULT" = true ]; then
    echo "Filtering adult content..."

    # 1. Create mapping: IMDB_ID -> Hash
    cat "$TEMP_DIR"/page_*.json | jq -r '.imdb + "," + (.torrents[].hash)' > "$TEMP_DIR/hash_to_imdb_map.txt"

    # 2. Extract unique IMDB IDs from our selection and find which are "adult"
    awk -F'\t' 'NR==FNR { adult_imdb_set[$1]; next } 
                $5=="1" && ($1 in adult_imdb_set)' \
        <(awk -F',' 'NR==FNR{hashes[$1]; next} ($2 in hashes) {print $1}' "$TEMP_DIR/selected_torrents.txt" "$TEMP_DIR/hash_to_imdb_map.txt" | sort -u) \
        "$IMDB_FILE" > "$TEMP_DIR/adult_imdb_ids.txt"

    # 3. Final Filter: Only keep hashes whose IMDB ID is NOT in the adult_imdb_ids.txt
    awk -F',' 'NR==FNR { adult_ids[$1]; next } !($1 in adult_ids) { print $2 }' \
    "$TEMP_DIR/adult_imdb_ids.txt" \
    "$TEMP_DIR/hash_to_imdb_map.txt" > "$TEMP_DIR/filtered_torrents.txt"

    mv "$TEMP_DIR/filtered_torrents.txt" "$TEMP_DIR/selected_torrents.txt"
    
fi



mv "$TEMP_DIR/filtered_torrents.txt" "$TEMP_DIR/selected_torrents.txt"

# --- PHASE 3: Torbox Cache Check ---
# Check if hash is cached on Torbox
echo "Checking cache in batches..."
split -l "$BATCH_SIZE" "$TEMP_DIR/selected_torrents.txt" "$TEMP_DIR/chunk_"
touch "$TEMP_DIR/raw_cached_hashes.txt"
TOTAL_CHUNKS=$(ls -1 "$TEMP_DIR"/chunk_* | wc -l)
CURRENT_CHUNK=0

# Loop through chunks, checking cache status via Torbox API
for CHUNK in "$TEMP_DIR"/chunk_*; do
    ((CURRENT_CHUNK++))
    JSON_HASHES=$(cat "$CHUNK" | jq -R . | jq -s .)
    while true; do
        RES=$(curl -s -w "\n%{http_code}" -X POST "$TORBOX_CHECK_URL" -H "Authorization: Bearer $TORBOX_API_KEY" -H "Content-Type: application/json" -d "{\"hashes\": $JSON_HASHES}")
        if [ "$(echo "$RES" | tail -n1)" -eq 429 ]; then sleep 15; continue; fi
        echo "$RES" | sed '$d' | jq -r '.data | keys[]?' >> "$TEMP_DIR/raw_cached_hashes.txt"
        break
    done
    printf "\rCache Check: [%-40s] %d/%d" "$(printf '#%.0s' $(seq 1 $((CURRENT_CHUNK * 40 / TOTAL_CHUNKS))))" "$CURRENT_CHUNK" "$TOTAL_CHUNKS"
    sleep 0.21
done

# --- PHASE 4: Add to TorBox ---
# Add torrent to Torbox
# Sleep 15 on 429 rate limit
CACHED_HASHES=$(wc -l < "$TEMP_DIR/raw_cached_hashes.txt" | tr -d ' ')
echo -e "\nAdding $CACHED_HASHES torrents to TorBox..."
COUNTER=0
while IFS= read -r HASH; do
    [ -z "$HASH" ] && continue
    ((COUNTER++))
    while true; do
        RES=$(curl -s -w "\n%{http_code}" -X POST "$TORBOX_CREATE_URL" -H "Authorization: Bearer $TORBOX_API_KEY" -F "magnet=magnet:?xt=urn:btih:$HASH")
        if [ "$(echo "$RES" | tail -n1)" -eq 429 ]; then sleep 15; continue; fi
        break
    done
    printf "\rAdding: %d/%d" "$COUNTER" "$CACHED_HASHES"
    sleep 0.21
done < "$TEMP_DIR/raw_cached_hashes.txt"

echo -e "\nProcess complete."
