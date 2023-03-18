#!/bin/bash

## Configurable ##
ROOT_DIR=/home/awalsh128/Scanned
# Don't make any changes
DRY_RUN=false
# Disable option for manual entry if automatic update fails.
MANUAL_DISABLED=true
# Preview the image before entering it or during it.
# The image viewer will take the focus off the terminal resulting in an extra click.
PREVIEW_BEFORE_ENTRY=true
PREVIEW_BEFORE_ENTRY_TIME=1

# Timezone offset (e.g. -08 PT)
TZ_OFFSET="-08"
# Image dimensions
IMAGE_DIMENSIONS="700x700+200+100"
# Update files that are more recent instead of updating by filename.
SHOULD_UPDATE_DAYS_GT=356
# Directories
PENDING_DIR="$ROOT_DIR/Pending"
PROCESSED_DIR="$ROOT_DIR/Processed"
ARCHIVED_DIR="$ROOT_DIR/Archived"

PROPAGATED_DT_TAGS="\"-EXIF:OffsetTime*=-08:00\" -AllDates<DateTimeOriginal -FileModifyDate<DateTimeOriginal"
# Needed for looping over filenames with spaces.
IFS=$'\n'

usage() {
  echo "usage: $(basename "$0") [OPTION]

Read and write photo's EXIF OriginalDateTime tag.

  -a, --autoprocess     only process dated pending filenames in $PENDING_DIR
  -b, --batch DIR DATE  batch update a directory with a single date
  -p, --process         process pending files in $PENDING_DIR
  -r, --review          review the processed files in $PROCESSED_DIR
  -m, --manual FILE     manually update an individual file
  -h, --help            display this help and exit"
}

check_arity() {
  [[ $# == $1 ]] && error 1 "too many arguments provided -- $@"
}

main() {
  [[ -z $(which exiftool) ]] && error 20 "exiftool not found. Install with 'sudo apt install exiftool'."

  SHORT_OPTS=a,b,m,p,r,h
  LONG_OPTS=autoprocess,batch,manual,process,review,help
  VALID_ARGS=$(getopt -o $SHORT_OPTS --long $LONG_OPTS -- "$@")

  [[ $# == 0 ]] && error 2 "no arguments provided"  
  eval set -- "$VALID_ARGS"
  [[ $? != 0 ]] && error 3

  for dir in "$PROCESSED_DIR" "$ARCHIVED_DIR"; do [[ ! -d $dir ]] && mkdir "$dir"; done

  case "$1" in
    -a | --autoprocess)
      check_arity 0
      process_files true # disable manual entry
      ;;
    -b | --batch)
      check_arity 2
      update_batch "$3" "$4" # directory, input_date
      ;;
    -p | --process)
      check_arity 0
      process_files false
      ;;
    -m | --manual)
      check_arity 1
      ! [[ -f "$2" ]] && error 4 "file $2 not found"      
      update_manually "$2" # filename
      ;;
    -r | --review)
      check_arity 0
      review_files "$PROCESSED_DIR"
      ;;
    -h | --help)
      [[ $# > 2 ]] && error 5 $arg_error_error
      usage
      ;;
    *)
      error 2 "invalid option '$1' provided"
      ;;
  esac
}

error() {
  local code=$1
  local message=$2
  [[ -n $message ]] && echo -e "error: $message\n"  
  usage
  exit $code
}

list_files() {
  local dir=$1
  for filename in $(find "$dir" -type f -printf "%T@:%p\n" | sort -n | awk -F: '{print $2}'); do
    $(file "$filename" | grep 'image' > /dev/null) && echo $filename
  done
}

move_file() {
  local filename=$1
  mv "$filename" "$(print_exif_filename "$filename")" "$PROCESSED_DIR"
  local original_filename="${filename}_original"
  [[ -f "$original_filename" ]] && mv "$original_filename" "$ARCHIVED_DIR/$(basename "$filename")"
}

print_date_delta() {
  local t1=$(date --date="$1" +%s)
  local t2=$(date --date="$2" +%s)
  local delta=$(( ($t1 - $t2 ) / (60*60*24) ))
  echo ${delta#-}
}

print_exif_tag() {
  local filename="$1"
  local tag=$2
  exiftool -s -s -s "$filename" -$tag
}

print_exif_description() {
  local filename="$1"
  print_exif_tag "$filename" "XMP-dc:Description"  
}

print_exif_date_tag() {
  local filename="$1"
  local tag=$2
  echo $(print_exif_tag "$filename" $tag) | awk -F" " '{print $1}' | tr ':' '-'
}

print_exif_date_orig() {
  print_exif_date_tag "$1" "DateTimeOriginal"  
}

print_filename_date() {
  local extensionless=$(basename "$filename" | awk -F. '{print $1}')
  local candidate=$(echo $extensionless | awk -F'[ -]' '{print $1"-"$2"-"$3}')
  if date "+%Y-%m-%d" -d "$candidate" &> /dev/null ; then
    echo "$candidate"
  else
    echo ""
  fi
}

print_full_date() {
  local value=$1
  local candidate=""
  local format=""
  if [[ $value =~ ^[0-9]{4}$ ]]; then
    candidate="$value-01-01"
  elif [[ $value =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    candidate="$value-01"
  elif [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    candidate="$value"
  elif [[ $value =~ ^([0-9]{4})([0-9]{2})$ ]]; then
    candidate="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-01"
  elif [[ $value =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    candidate="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
  else
    echo ""
    return
  fi
  if date "+%Y-%m-%d" -d "$candidate" &> /dev/null ; then
    echo "$candidate"
  else
    echo ""
  fi
}

print_exif_filename() {
  local filename=$1
  local target_dir=$2  
  local exif_date=$(print_exif_date_orig "$filename")
  if [[ -z "$exif_date" ]]; then
    echo "$(basename "$filename") does not contain DateTimeOriginal tag"
    exit 10
  fi
  local extension=$(file --brief --extension "$filename" | awk -F/ '{print $1}')
  local counter=0
  while :; do
    new_filename=$(printf "%s/%s-%04d.%s" "$target_dir" $exif_date $counter $extension)
    if [[ ! -f "$new_filename" ]]; then
      echo "$new_filename"
      break;
    fi
    counter=$(expr $counter + 1)
  done
}

print_friendly_text() {
  local value=$1
  [[ -n "$value" ]] && echo "none" || echo $value
}

process_file() {
  local filename=$1
  local manual_disabled=$2

  echo "filename          : $(basename "$filename")"

  local orig_exif_date=$(print_exif_date_orig "$filename")
  echo "orig exif date    : $(print_friendly_text $orig_exif_date)"

  echo -n "action            : "  
  local filename_date=$(print_filename_date "$filename")
  if should_update "$filename_date" ; then
    echo "update from filename"
    update "$filename" "$filename_date" ""
  else
    if [[ $manual_disabled == "true" ]]; then
      echo "skip, manual prompt disabled"
      return
    fi
    echo "update from prompt"
    update_manually "$filename"
  fi

  local updated_exif_date=$(print_exif_date_orig "$filename")
  echo "updated exif date : $(print_friendly_text $updated_exif_date)"

  move_file "$filename"  
}

process_files() {
  local manual_disabled=$1  
  local filenames=$(list_files $PENDING_DIR)
  if [[ -z "$filenames" ]]; then
    echo "No files found."
    return
  fi
  for filename in $filenames; do    
    process_file "$filename" $manual_disabled
    echo ""
  done
}

review_files() {
  local dir=$1
  local filenames=$(list_files $dir)  
  local max_length=30
  local format="%-${max_length}s %-10s %-10s  %s\n"

  printf "$format" "Filename" "Original" "Modified" "Description"
  for filename in $filenames; do 
    printf "$format" \
      "$(basename "$filename")" \
      "$(print_exif_date_orig "$filename")" \
      "$(print_exif_date_tag "$filename" "FileModifyDate")" \
      "$(print_exif_description "$filename")"
  done
}

should_update() {
  local exif_date=$1
  [[ -n "$exif_date" ]] && [[ $(print_date_delta `date +%F` $exif_date) -gt $SHOULD_UPDATE_DAYS_GT ]]
}

update() {
  local filename=$1
  local date=$2
  local description=$3

  if [[ $DRY_RUN == "true" ]]; then
    echo "skipping update, in dry run mode"
    return
  fi

  update_exec "$filename" "$date" "$description" 
  move_file "$filename"  
}

update_batch() {
  local dir=$1
  local input_date=$2
  local description=$3

  [[ ! -d "$dir" ]] && error 6 "$dir does not exist"
  
  local full_date=$(print_full_date $input_date)
  [[ ! -n $full_date ]] && error 7 "$input_date is not a valid date"
  
  echo -e "Batch processing files in $dir\n"
  echo "exif date : $full_date"
  for filename in $(list_files $dir); do
    echo "filename  : $filename"
    update "$filename" "$full_date" "$description"
  done
}

update_exec() {
  local filename=$1
  local date=$2
  local description=$3

  local value=""
  [[ -n "$date" ]] && value=$(echo $date "12:00:00" | tr '-' ':')
  
  if [[ -n "$description" ]]; then
    exiftool -EXIF:OffsetTime*="$TZ_OFFSET:00" -AllDates="$value" -FileModifyDate="$value" -XMP-dc:Description="$description" "$filename" > /dev/null
  else
    exiftool -EXIF:OffsetTime*="$TZ_OFFSET:00" -AllDates="$value" -FileModifyDate="$value" "$filename" > /dev/null
  fi
}

update_manually() {
  local filename=$1
  
  feh -x --scale-down -g $IMAGE_DIMENSIONS "$filename"&
  local feh_pid=$!
  if [[ $PREVIEW_BEFORE_ENTRY == "true" ]]; then
    sleep $PREVIEW_BEFORE_ENTRY_TIME
    kill $feh_pid
  fi

  local full_date=""
  while :; do
    echo -n "enter date        : "
    read input_date
    if [[ -z $input_date ]]; then
      break
    else
      full_date=$(print_full_date $input_date)
      if [[ -n $full_date ]]; then
        update "$filename" "$full_date"
        break
      else
        echo "error: $input_date is not a valid date"
      fi
    fi
  done

  echo -n "enter description : "    
  read input_description

  update "$filename" "$full_date" "$input_description"

  [[ $PREVIEW_BEFORE_ENTRY != "true" ]] && kill $feh_pid
}

################################################################################################################################
# Ad-hoc Recipes - Uncomment to use.
#
# Update processed files' dates from DateTimeOriginal.
# find f in $(list_files $PROCESSED_DIR); do; echo $f; exiftool "-EXIF:OffsetTime*=-08:00" -AllDates<DateTimeOriginal -FileModifyDate<DateTimeOriginal "$f"; done; exit
#
# Print any processed files with missing DateTimeOriginal.
# for f in $(list_files $PROCESSED_DIR); do [[ -z "$(print_exif_date_orig "$f")" ]] && echo $f; done; exit
#
# Delete intermediate files that may have been left around.
# find $ROOT_DIR -type f -name *_original -o -name *_exiftool_tmp -exec rm -f {} \;; exit
#
# Delete tags for reprocessing. Can't delete FileModifyDate though.
# for filename in $(list_files "Scanned/Pending Dated"); do exiftool "-EXIF:OffsetTime*=" "-AllDates=" "$filename"; done; exit
#
################################################################################################################################

main "$@"; exit
