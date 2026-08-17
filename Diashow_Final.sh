#!/bin/bash

# --- Einstellungen ---
BILD_DAUER=9
BLEND_DAUER=2
BREITE=1920
HOEHE=1080
FPS=30
ZOOM_SPEED="0.00003" 

# --- Upscale-Multiplikator für Bilder ---
WORK_MULTI=4
WORK_B=$((BREITE * WORK_MULTI))
WORK_H=$((HOEHE * WORK_MULTI))

# --- Dateien ---
FILTER_SCRIPT="diashow_filter.txt"
LOG_FILE="diashow_log.txt"

# Aufräumen bei Skript-Ende oder Abbruch (Ctrl+C)
cleanup() {
    rm -f "$FILTER_SCRIPT"
}
trap cleanup EXIT INT TERM

# =========================================================================
# AB HIER STARTET DER LOG-BLOCK (Alles innerhalb der {klammern} wird geloggt)
# =========================================================================
{
    echo "======================================================="
    echo "=== Diashow-Generator gestartet: $(date +'%d.%m.%Y %H:%M:%S') ==="
    echo "======================================================="

    if ! command -v ffprobe &> /dev/null; then
        echo "FEHLER: 'ffprobe' wurde nicht gefunden!"
        exit 1
    fi

    # --- Dateien einlesen ---
    echo "Schritt 1: Suche nach JPG-, PNG- und MP4-Dateien..."
    shopt -s nullglob 
    dateien=(*.[jJ][pP][gG] *.[jJ][pP][eE][gG] *.[pP][nN][gG] *.[mM][pP]4)
    anzahl=${#dateien[@]}
    shopt -u nullglob 

    if [ "$anzahl" -eq 0 ]; then
        echo "FEHLER: Keine passenden Dateien gefunden!"
        exit 1
    fi

    if [ "$anzahl" -eq 1 ]; then
        echo "FEHLER: Mindestens 2 Dateien werden benötigt!"
        exit 1
    fi

    echo "-> $anzahl Dateien erfolgreich gefunden."
    gesamtlaufzeit=$(( (anzahl * BILD_DAUER) - ((anzahl - 1) * BLEND_DAUER) ))
    gesamtdauer_min=$(( gesamtlaufzeit / 60 ))
    echo "-> Das fertige Video wird ca. $gesamtlaufzeit Sekunden ($gesamtdauer_min Minuten) lang sein."
    echo "----------------------------------------"

    # Filter-Datei initialisieren (leeren)
    > "$FILTER_SCRIPT"

    input_args=()

    echo "Schritt 2: Schreibe Filterkette in '$FILTER_SCRIPT'..."

    # 1. Hauptschleife: Eingaben & individuelle Filter
    for ((i=0; i<anzahl; i++)); do
        datei="${dateien[$i]}"
        endung="${datei##*.}"
        endung_klein=$(echo "$endung" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$endung_klein" == "mp4" ]]; then
            input_args+=(-stream_loop -1 -t "$BILD_DAUER" -i "$datei")
            
            # Video-Filter
            echo "[$i:v]format=yuv420p,scale=w=${BREITE}:h=${HOEHE}:force_original_aspect_ratio=decrease,pad=w=${BREITE}:h=${HOEHE}:x=(ow-iw)/2:y=(oh-ih)/2:color=black,fps=${FPS},setsar=1[v$i];" >> "$FILTER_SCRIPT"
            
            # Audio-Filter
            has_audio=$(ffprobe -loglevel error -show_streams -select_streams a "$datei")
            if [ -n "$has_audio" ]; then
                echo "[$i:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,atrim=0:${BILD_DAUER},asetpts=PTS-STARTPTS[a$i];" >> "$FILTER_SCRIPT"
            else
                echo "anullsrc=r=48000:cl=stereo:d=${BILD_DAUER}[a$i];" >> "$FILTER_SCRIPT"
            fi
        else
            input_args+=(-i "$datei")
            frames=$((BILD_DAUER * FPS))
            
            # Bild-Filter
            echo "[$i:v]format=yuv420p,scale=w=${WORK_B}:h=${WORK_H}:force_original_aspect_ratio=decrease,pad=w=${WORK_B}:h=${WORK_H}:x=(ow-iw)/2:y=(oh-ih)/2:color=black,setsar=1,zoompan=z='zoom+${ZOOM_SPEED}':x='iw/2-(iw/zoom)/2':y='ih/2-(ih/zoom)/2':d=${frames}:s=${BREITE}x${HOEHE}:fps=${FPS}[v$i];" >> "$FILTER_SCRIPT"
            
            # Stummes Audio für Bilder
            echo "anullsrc=r=48000:cl=stereo:d=${BILD_DAUER}[a$i];" >> "$FILTER_SCRIPT"
        fi
    done

    # 2. Schleife für Video- und Audio-Überblendungen
    offset=$((BILD_DAUER - BLEND_DAUER))
    current_v="[v0]"
    current_a="[a0]"

    for ((i=1; i<anzahl; i++)); do
        next_v="[xf_v$i]"
        next_a="[xf_a$i]"
        
        if [ "$i" -eq $((anzahl - 1)) ]; then
            next_v="[vout]"
            next_a="[aout]"
        fi
        
        echo "${current_v}[v$i]xfade=transition=fade:duration=${BLEND_DAUER}:offset=${offset}${next_v};" >> "$FILTER_SCRIPT"
        echo "${current_a}[a$i]acrossfade=d=${BLEND_DAUER}${next_a};" >> "$FILTER_SCRIPT"
        
        current_v="${next_v}"
        current_a="${next_a}"
        offset=$((offset + BILD_DAUER - BLEND_DAUER))
    done

    # Letztes Semikolon in der Datei entfernen
    sed -i '$ s/;$//' "$FILTER_SCRIPT"

    echo "-> Filterdatei erfolgreich erstellt."
    echo "----------------------------------------"

    # --- FFmpeg mit -filter_complex_script ausführen ---
    output_file="diashow_final.mp4"

    echo "Schritt 3: Starte den Rendervorgang (FFmpeg)..."
    echo "(Hinweis: Bei großen Dateimengen wird das Rendern einige Zeit dauern.)"
    echo ""

    ffmpeg "${input_args[@]}" \
        -filter_complex_script "$FILTER_SCRIPT" \
        -map "[vout]" -map "[aout]" \
        -r "$FPS" \
        -pix_fmt yuv420p \
        -c:a aac -b:a 192k \
        -preset veryfast \
        -loglevel error -stats \
        "$output_file"

    echo ""
    echo "----------------------------------------"
    echo "=== FERTIG: $(date +'%d.%m.%Y %H:%M:%S') ==="
    echo "Die Diashow wurde erfolgreich als '$output_file' gespeichert."
    echo "Ein detailliertes Protokoll wurde in '$LOG_FILE' gespeichert."

} 2>&1 | tee "$LOG_FILE"
# =========================================================================
# ENDE DES LOG-BLOCKS
# =========================================================================
