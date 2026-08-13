#!/bin/bash

# --- Einstellungen ---
BILD_DAUER=7
BLEND_DAUER=2
BREITE=1920
HOEHE=1080
FPS=30
ZOOM_SPEED="0.00003" 

# --- DER UPSCALE-TRICK ---
WORK_MULTI=4
WORK_B=$((BREITE * WORK_MULTI))
WORK_H=$((HOEHE * WORK_MULTI))

echo "=== Diashow-Generator wird gestartet ==="

# --- Bilder in ein Array laden ---
echo "Schritt 1: Suche nach JPG- und PNG-Bildern im aktuellen Ordner..."

# WICHTIG: Verhindert Fehler, falls ein Dateityp im Ordner fehlt
shopt -s nullglob 

# Lädt JPG, JPEG und PNG (egal ob groß- oder kleingeschrieben)
bilder=(*.[jJ][pP][gG] *.[jJ][pP][eE][gG] *.[pP][nN][gG])
anzahl=${#bilder[@]}

# nullglob wieder deaktivieren (guter Programmierstil)
shopt -u nullglob 

if [ $anzahl -eq 0 ]; then
    echo "FEHLER: Keine passenden JPG- oder PNG-Bilder gefunden!"
    exit 1
fi

if [ $anzahl -eq 1 ]; then
    echo "FEHLER: Für eine Überblendung werden mindestens 2 Bilder benötigt!"
    exit 1
fi

echo "-> $anzahl Bilder erfolgreich gefunden."

# Gesamtlänge berechnen
gesamtlaufzeit=$(( (anzahl * BILD_DAUER) - ((anzahl - 1) * BLEND_DAUER) ))
echo "-> Das fertige Video wird ca. $gesamtlaufzeit Sekunden lang sein."
echo "----------------------------------------"

input_args=()
filter=""

echo "Schritt 2: Generiere die FFmpeg-Filterkette (Zoom & Crossfade)..."

# 1. Hauptschleife
for ((i=0; i<anzahl; i++)); do
    bild="${bilder[$i]}"
    input_args+=(-i "$bild")
    
    frames=$((BILD_DAUER * FPS))
    filter="${filter}[$i:v]format=yuv420p,scale=w=${WORK_B}:h=${WORK_H}:force_original_aspect_ratio=decrease,pad=w=${WORK_B}:h=${WORK_H}:x=(ow-iw)/2:y=(oh-ih)/2:color=black,setsar=1,zoompan=z='zoom+${ZOOM_SPEED}':x='iw/2-(iw/zoom)/2':y='ih/2-(ih/zoom)/2':d=${frames}:s=${BREITE}x${HOEHE}:fps=${FPS}[v$i];"
done

# 2. xfade-Schleife (Überblendungen)
offset=$((BILD_DAUER - BLEND_DAUER))
current_out="[v0]"

for ((i=1; i<anzahl; i++)); do
    next_out="[xf$i]"
    if [ $i -eq $((anzahl - 1)) ]; then
        next_out="[out]"
    fi
    
    filter="${filter}${current_out}[v$i]xfade=transition=fade:duration=${BLEND_DAUER}:offset=${offset}${next_out};"
    
    current_out="${next_out}"
    offset=$((offset + BILD_DAUER - BLEND_DAUER))
done

filter=${filter%?}
echo "-> Filterkette erfolgreich erstellt."
echo "----------------------------------------"

# --- Kompletten FFmpeg-Befehl ausführen ---
output_file="diashow_mit_png.mp4"

echo "Schritt 3: Starte den Rendervorgang (FFmpeg)..."
echo "(Hinweis: Dank '-stats' siehst du unten den Live-Fortschritt. Warnungen werden ignoriert.)"
echo ""

ffmpeg "${input_args[@]}" -filter_complex "${filter}" -map "[out]" -r "$FPS" -pix_fmt yuv420p -preset veryfast -loglevel error -stats "$output_file"

echo ""
echo "----------------------------------------"
echo "=== FERTIG! ==="
echo "Die Diashow wurde erfolgreich als '$output_file' gespeichert."
