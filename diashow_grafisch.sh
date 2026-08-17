#!/bin/bash

# Prüfen, ob Zenity für die GUI installiert ist
if ! command -v zenity &> /dev/null; then
    echo "FEHLER: 'zenity' ist nicht installiert."
    sleep 5
    exit 1
fi

# =========================================================================
# 1. GUI-FENSTER: ORDNER AUSWÄHLEN
# =========================================================================
ZIEL_ORDNER=$(zenity --file-selection --directory --title="Wähle den Ordner mit deinen Bildern und Videos aus")

# Wenn der Benutzer auf "Abbrechen" klickt, Skript beenden
if [ $? -ne 0 ]; then 
    exit 1 
fi

# Skript wechselt unsichtbar in den gewählten Ordner
cd "$ZIEL_ORDNER" || { zenity --error --text="Fehler: Konnte nicht in den Ordner wechseln."; exit 1; }

# =========================================================================
# 2. GUI-FENSTER: EINSTELLUNGEN ABFRAGEN
# =========================================================================
BILD_DAUER=$(zenity --entry --title="Diashow Generator (1/4)" --text="Dauer pro Bild (Sekunden):" --entry-text="7")
if [ $? -ne 0 ]; then exit 1; fi

BLEND_DAUER=$(zenity --entry --title="Diashow Generator (2/4)" --text="Dauer der Überblendung (Sekunden):" --entry-text="2")
if [ $? -ne 0 ]; then exit 1; fi

FPS=$(zenity --entry --title="Diashow Generator (3/4)" --text="Framerate (FPS):" --entry-text="30")
if [ $? -ne 0 ]; then exit 1; fi

OUTPUT_FILE=$(zenity --entry --title="Diashow Generator (4/4)" --text="Dateiname (mit .mp4):" --entry-text="diashow_final.mp4")
if [ $? -ne 0 ]; then exit 1; fi

# Fallbacks: Wenn ein Feld komplett leer gelöscht wurde, setze den Standardwert ein
BILD_DAUER=${BILD_DAUER:-7}
BLEND_DAUER=${BLEND_DAUER:-2}
FPS=${FPS:-30}
OUTPUT_FILE=${OUTPUT_FILE:-"diashow_final.mp4"}

# Feste Einstellungen, die wir im Hintergrund behalten
BREITE=1920
HOEHE=1080
ZOOM_SPEED="0.00003" 
WORK_MULTI=4
WORK_B=$((BREITE * WORK_MULTI))
WORK_H=$((HOEHE * WORK_MULTI))
FILTER_SCRIPT="diashow_filter.txt"
LOG_FILE="diashow_log.txt"

# Aufräumen bei Skript-Ende oder Abbruch (Ctrl+C)
cleanup() {
    rm -f "$FILTER_SCRIPT"
}
trap cleanup EXIT INT TERM

# =========================================================================
# 3. LOGIK & BERECHNUNG (Im Hintergrund in GUI umgeleitet)
# =========================================================================
{
    echo "=== Diashow-Generator gestartet: $(date +'%d.%m.%Y %H:%M:%S') ==="
    echo "Ordner: $ZIEL_ORDNER"
    echo "Einstellungen: ${BILD_DAUER}s pro Bild | ${BLEND_DAUER}s Blend | ${FPS} FPS"
    echo "======================================================="

    if ! command -v ffprobe &> /dev/null; then
        echo "FEHLER: 'ffprobe' wurde nicht gefunden!"
        exit 1
    fi

    echo "Suche nach Dateien..."
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

    gesamtlaufzeit=$(( (anzahl * BILD_DAUER) - ((anzahl - 1) * BLEND_DAUER) ))
    gesamtdauer_min=$(( gesamtlaufzeit / 60 ))
    echo "-> $anzahl Dateien erfolgreich gefunden."
    echo "-> Das fertige Video wird ca. $gesamtlaufzeit Sekunden ($gesamtdauer_min Minuten) lang sein."
    echo "----------------------------------------"

    > "$FILTER_SCRIPT"
    input_args=()

    echo "Schreibe komplexe Filterkette..."
    for ((i=0; i<anzahl; i++)); do
        datei="${dateien[$i]}"
        endung="${datei##*.}"
        endung_klein=$(echo "$endung" | tr '[:upper:]' '[:lower:]')
        
        if [[ "$endung_klein" == "mp4" ]]; then
            input_args+=(-stream_loop -1 -t "$BILD_DAUER" -i "$datei")
            echo "[$i:v]format=yuv420p,scale=w=${BREITE}:h=${HOEHE}:force_original_aspect_ratio=decrease,pad=w=${BREITE}:h=${HOEHE}:x=(ow-iw)/2:y=(oh-ih)/2:color=black,fps=${FPS},setsar=1[v$i];" >> "$FILTER_SCRIPT"
            
            has_audio=$(ffprobe -loglevel error -show_streams -select_streams a "$datei")
            if [ -n "$has_audio" ]; then
                echo "[$i:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,atrim=0:${BILD_DAUER},asetpts=PTS-STARTPTS[a$i];" >> "$FILTER_SCRIPT"
            else
                echo "anullsrc=r=48000:cl=stereo:d=${BILD_DAUER}[a$i];" >> "$FILTER_SCRIPT"
            fi
        else
            input_args+=(-i "$datei")
            frames=$((BILD_DAUER * FPS))
            echo "[$i:v]format=yuv420p,scale=w=${WORK_B}:h=${WORK_H}:force_original_aspect_ratio=decrease,pad=w=${WORK_B}:h=${WORK_H}:x=(ow-iw)/2:y=(oh-ih)/2:color=black,setsar=1,zoompan=z='zoom+${ZOOM_SPEED}':x='iw/2-(iw/zoom)/2':y='ih/2-(ih/zoom)/2':d=${frames}:s=${BREITE}x${HOEHE}:fps=${FPS}[v$i];" >> "$FILTER_SCRIPT"
            echo "anullsrc=r=48000:cl=stereo:d=${BILD_DAUER}[a$i];" >> "$FILTER_SCRIPT"
        fi
    done

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

    sed -i '$ s/;$//' "$FILTER_SCRIPT"
    echo "-> Filterdatei erfolgreich erstellt."
    echo "----------------------------------------"
    echo "Starte Rendervorgang (FFmpeg)..."
    echo "Bitte dieses Fenster offen lassen. Es schließt sich nicht automatisch, damit du das Log prüfen kannst."
    echo ""

    ffmpeg "${input_args[@]}" \
        -filter_complex_script "$FILTER_SCRIPT" \
        -map "[vout]" -map "[aout]" \
        -r "$FPS" \
        -pix_fmt yuv420p \
        -c:a aac -b:a 192k \
        -preset veryfast \
        -loglevel error -stats \
        "$OUTPUT_FILE"

    echo ""
    echo "----------------------------------------"
    echo "=== FERTIG! ==="
    echo "Video wurde gespeichert als: $ZIEL_ORDNER/$OUTPUT_FILE"
    
} 2>&1 | tee "$LOG_FILE" | zenity --text-info \
    --title="Diashow wird erstellt..." \
    --width=800 \
    --height=500 \
    --auto-scroll \
    --ok-label="Schließen"

# Wenn Zenity geschlossen wird, zeige noch eine kleine Erfolgsmeldung an
zenity --info --title="Erledigt" --text="Die Diashow wurde erfolgreich erstellt!\n\nOrdner: $ZIEL_ORDNER\nDatei: $OUTPUT_FILE\nLogdatei: $LOG_FILE"
