#!/bin/bash

################################### LICENSE ###################################
#
# This software is lincesed using the MIT License
# 
# Copyright (c) 2016 John Mark Mitchell
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
###############################################################################


################################# READ ME TOO #################################
# tl;dr: Move files to target without loss. Clean up source directory.
# 
# Intended use:
# The principal use of this script is to move files from a source directory to
# a target directory, on the same filesystem, via fail-safe handling.
#
# For more background information, usage suggestions and the latest version of
# this script, please visit: https://github.com/jmmitchell
#
#
# What it not intended for:
# This software not intended for opying files to remote file systems. Rsync, 
# Unison, SyncThing or a host of other options will serve you well. In
# addition, this is software really not intended to be backup software, though
# it certainly could be part of your overall backup plan.
#
# 
# Strengths over alternative options:
# This script is intended to provide finer-grained handling of file moving of
# local filesystem contents over other alternatives, like rsync or mv alone.
# While there may be faster or less complicted ways to move files, this script
# has been crafted to err on the side of data preservation and tracking every
# create/update/delete action in a timestamped log. This means that files are
# should never be overwritten; directories that are marked for deletion will
# fail to be deleted if they, for unforseen reasons, are not empty; ...
# 
# For those more familiar with linux cli handiwork, think of this script as
# the best of rsyc, find, mv, mkdir & rmdir rolled into one.
#
#
# Key features:
# - directories cleaned up from source directory (rsync does not do this)
# - via optional config file, source subdirs can be selectively preserved
# - consistent timestamped logging of all create/update/delete actions
# - logging of all items removed from source (not found in rsync)
# - warning messages in logs capture error information
# - warging messages in logs include stderr and return code of failed command
# - two levels of verbose message when run interactively
# - target directory structure will be created, if needed
# - via optional config file, ownership rules can be specified for items 
#   moved to the target directory
# - each potential file collisions (files with the same name & date) are
#   verified via checksum of both source and target files
# - verified file collisions are moved to the target via deconflicted filename
#   as opposed to rsync delta copy that might replicate a partial written file
# - exact duplicate files, verified via checksum, are not replicated
# - if source and target on the same filesystem, files are "moved" super fast
#   via meta date update (directory entries) rather than file contents
# - file-level atomic move so that there should never be a partially moved file
#
#
# The details: 
# 1. Using rsync, look in the source directory for files, directories and links
#    that need to be moved to the destination directory.
# 2. Using rsync, replicate the identified structural items (folders & links)
#    to the destination directory, applying attribute changes as needed to
#    mirror the source. Once replicated, rsync will remove the source items. An
#    exception to this is subdirectories. These are handled last.
# 3. For completely new files found in the source directory, move them via the
#    mv command.
# 4. Manage any possible file collisions by making offending source file names
#    unique before moving them to the target directory. The the collision-free
#    change list is fed to mv to complete the move from source to destination.
# 5. For files that appear exactly the same (size, attributes and change date)
#    in the source and destination, check each via hash against the matching
#    destination file. If the hashes match, there is no need to mv the file, so
#    the source file is deleted. Else, move the file via unique file name.
# 6. If changes were made in the destination directory, check the supplied
#    ownership config file and reinforce ownership as indicated.
# 7. Look for stale, empty directories in the source directory and remove them.
#    Staleness is determined by the change date as compared to the number of
#    minutes passed into the flag --minutes-until-stale (or -ms for short). If
#    no flag is set, staleness defaults to 15 mins.
#
#                              *** IMPORTANT ***
# It is important to use flock when running this script from a crontab. This
# allows the script to be executed often but keeps the system from having
# simultaneous copies of the script running. Not only is this resource (CPU, 
# RAM) friendly, this eliminates race conditions and other nasty unintended
# side effects. For more information, see the readme for the project on github:
# https://github.com/jmmitchell
#                              *****************
#
#                              **** WARNING ****
# It should be recognized that while this script makes every attempt to fail
# safely, there are most probably edge cases that are not accounted for, so
# proceed with caution, question everything and, if you find bugs please
# contribute back with a pull request. You have been warned.
#                              *****************
#
###############################################################################



################################## FUNCTIONS ##################################
#

function make_filename_unique {
    # were were passed anything
    if [ -n "$1" ]; then
        echo "${1}-deconflicted-$(date  +"%Y-%m-%d-%H-%M-%S-%N")"
    else
        echo ""
    fi
}

function uuid {
    local N B C='89ab'
    for (( N=0; N < 16; ++N )) ; do
        B=$(( RANDOM%256 ))
        case $N in
          6)
            printf -- '4%x' $(( B%16 ))
            ;;
          8)
            printf -- '%c%x' ${C:$RANDOM%${#C}:1} $(( B%16 ))
            ;;
          3 | 5 | 7 | 9)
            printf -- '%02x-' $B
            ;;
          *)
            printf -- '%02x' $B
            ;;
        esac
    done
    echo
}

function adddate {
    while IFS= read -r line; do
        printf -- '%s\t%s\n' "$(date)" "${line}"
    done <<<"${1}"
}

function logger {
    # was a param passed and does LOGFILE have some value
    if [ -n "$1" ] && [ -n "${LOGFILE}" ]; then
        # test if file exists and is writable
        if [[ ( -e "${LOGFILE}" || $(touch "${LOGFILE}") ) && -w "${LOGFILE}" ]]; then
            # prepend date then write to log, ensuring a newline at the end
            adddate "$1" >> "${LOGFILE}"
        fi
    fi
}

#
###############################################################################



##################### PROCESS ARGUMENTS & SET DEFAULTS ########################
#

# set some default values
MINSUNTILSTALE="15"
exit_now="0"

# use file descriptors 3 through 5 for our verbose output
# important to start counting at 2 so that any increase to this will result in
# a min of file descriptor 3 (remember 0-2 are used by stderr, stdin, stdout)
VERBOSITYMIN="2"

# to start VERBOSELEVEL = VERBOSITYMIN, effectively turning off verbosity
VERBOSELEVEL="${VERBOSITYMIN}"

# the highest verbosity level
VERBOSITYMAX="5" 


# process arguments passed to the script
for opt in "$@"; do
    case $opt in
      -v=*|--verbose=*)
        if [[ "${opt#*=}" =~ ^[1-3]$ ]]; then
            let VERBOSELEVEL+="${opt#*=}"
        fi
        make sure the arg was not parsed twice and resulting in gt VERBOSITYMAX
        if [[ "${VERBOSELEVEL}" > "${VERBOSITYMAX}" ]]; then
            VERBOSELEVEL="${VERBOSITYMAX}"
        fi
        shift # past argument=value
        ;;
      -v|--verbose)
        if [[ "${VERBOSELEVEL}" -lt "3" ]]; then
            VERBOSELEVEL="3"
        fi
        shift # past argument with no value
        ;;
      -s=*|--source=*)
        SOURCEPATH="${opt#*=}"
        if [ -d "${opt#*=}" ]; then
            # cd and pwd magic ensures that the path is fully qualified, but
            # without link expansion. pwd always returns paths without the
            # trailing slash and rsync is sensitive to this so we append one
            SOURCEPATH="$(cd "${opt#*=}"; pwd)/"
            # SOURCEPATH_SLASH_ESCAPED="${SOURCEPATH//\//\\/}"
            # SOURCEPATH_SPACE_ESCAPED="${SOURCEPATH// /\\ }"
        else
            printf -- '\n%s : the supplied source path is not valid. No such directory.\n' "${opt}"
            exit_now="1"
        fi
        shift # past argument=value
        ;;
      -d=*|--destination=*)
        DESTINATIONPATH="${opt#*=}"
        if [ -d "${opt#*=}" ]; then
            # cd and pwd magic ensures that the path is fully qualified, but
            # without link expansion. pwd always returns paths without the
            # trailing slash and rsync is sensitive to this so we append one
            DESTINATIONPATH="$(cd "${opt#*=}"; pwd)/"
            # DESTINATIONPATH_SLASH_ESCAPED="${DESTINATIONPATH//\//\\/}"
            # DESTINATIONPATH_SPACE_ESCAPED="${DESTINATIONPATH// /\\ }"
        else
            printf -- '\n%s : the supplied destination path is not valid. No such directory.\n' "${opt}"
            exit_now="1"
        fi
        shift # past argument=value
        ;;
      -p=*|--preserve=*)
        DIRSTOPRESERVEFILE="${opt#*=}"
        # test if file exists and is readable
        if ! [ -r "${DIRSTOPRESERVEFILE}" ]; then
            printf -- '\n%s : either the file does not exist or is not readable. Check that the path is correct and that permissions are set correctly.\n' "${opt}"
            exit_now="1"
        fi
        shift # past argument=value
        ;;
      -o=*|--ownership=*)
        OWNERSHIPFILE="${opt#*=}"
        # test if file exists and is readable
        if ! [ -r "${OWNERSHIPFILE}" ]; then
            printf -- '\n%s : either the file does not exist or is not readable. Check that the path is correct and that permissions are set correctly.\n' "${opt}"
            exit_now="1"
        fi
        shift # past argument=value
        ;;
      -ms=*|--minutes-until-stale=*)
        if [[ "${opt#*=}" =~ ^[0-9]+$ ]]; then
            MINSUNTILSTALE="${opt#*=}"
        fi
        shift # past argument=value
        ;;
      -l=*|--log=*)
        LOGFILE="${opt#*=}"
        # test if file exists and is writable
        if [[ ( -e "${LOGFILE}" || $(touch "${LOGFILE}") ) && ! -w "${LOGFILE}" ]]; then
            printf -- '\n%s : either the file does not exist or is not readable. Check that the path is correct and that permissions are set correctly.\n' "${opt}"
            exit_now="1"
        fi
        shift # past argument=value
        ;;
      *)
        # unknown option
        printf -- '\n%s : unknown option\n' "${opt}"
        ;;
    esac
done

# check for the minimum required arguments
if [ -z "${SOURCEPATH}" ] || [ -z "${DESTINATIONPATH}" ]; then
    printf -- '\n A source and target path are required arguments.\n'
    exit_now="1"
fi

# if critical information is missing or wrong, exit the script
if [ "${exit_now}" -eq "1" ]; then
    printf -- "\nPREVIOUS ISSUE(S) HAVE CAUSED A FATAL ERROR.\n\nExiting now.\n\n"
    exit 1;
fi


# open the file descriptors needed to handle verbose output
# start counting from 3 since 1 and 2 are standards (stdout/stderr).
for level in $(seq 3 "${VERBOSELEVEL}"); do
    (( "${level}" <= "${VERBOSITYMAX}" )) && eval exec "${level}>&2"  # Don't change anything higher than the maximum verbosity allowed.
done

# any handler higher than requested, pipe to null
for level in $(seq $(( VERBOSELEVEL+1 )) "${VERBOSITYMAX}" ); do
    # start at 3 (1 & 2 are stdout and stderr) direct these to bitbucket
    (( "${level}" >= "3" )) && eval exec "${level}>/dev/null" 
done



# if verbose output was triggered, list out the args
if [[ "${VERBOSELEVEL}" > "${VERBOSITYMIN}" ]]; then
    printf -- 'Verbose mode was triggered...\n'
    printf -- '   Verbose = %s\n' "${VERBOSELEVEL}"
    printf -- '   Source Path = %s\n' "${SOURCEPATH}"
    printf -- '   Destination Path = %s\n' "${DESTINATIONPATH}"
    printf -- '   Directories to Preserve File = %s\n' "${DIRSTOPRESERVEFILE}"
    printf -- '   Log File = %s\n' "${LOGFILE}"
    printf -- '   Ownership File = %s\n' "${OWNERSHIPFILE}"
    printf -- '   Minutes Until Directories Are Stale = %s\n\n' "${MINSUNTILSTALE}"
fi

#
###############################################################################



# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
# tl;dr: Move files from to destination while accounting for collision.
#
# The details: 
# 1. Rsync is employed to look for new changes in the source directory that are
#    not in the destination directory.
# 2. The --whole-file flag is used to force rsync to use name, size change
#    date/time to determine file uniqueness rather than using a file checksum.
#    This will help to keep CPU and RAM usage low.
#    NOTE this has one possible edge case that could be undesirable: if the 
#    source directory contained files, like those used in databases, where
#    changes could be made to the internals of the file and yet the file change
#    date and size remain unchanged, this change would go unnoticed by rsync
#    when run with the --whole-file flag. If this scenario is anticipated, be
#    certain to remove this flag below and test, test, test before relying on
#    this script to handle your precious data. If you do have these kind of
#    files it is recommended that utilize a utility specifically written for
#    backing up such files. Checksum is later used and would catch this change
#    so data would not be lost but for things like actively written DB data
#    files, look into the tools specifically designef to handle them.
#    right tool to back them up.
# 3. The --dry-run flag is used to force rsync to simultate the move but not
#    act on the changes, thus we get a targeted list of changes to process.
# 4. The combination of the --itemize-changes flag and the -vvv flag gives us
#    detailed output of any file system changes that rsync found in the source
#    directory when compared to the target directory. The bit flags produced by
#    rsync's itemized changes are parsed to determine required actions.
#    ------------------------------------------------------
#    For reference, example output of rsync bit flags:
#    >f+++++++++ some/dir/new-file.txt
#    .f....og..x some/dir/existing-file-with-changed-owner-and-group.txt
#    .f........x some/dir/existing-file-with-changed-unnamed-attribute.txt
#    >f...pog..x some/dir/existing-file-with-changed-permissions.txt
#    >f..t.og..x some/dir/existing-file-with-changed-time.txt
#    >f.s..og..x some/dir/existing-file-with-changed-size.txt
#    >f.st.og..x some/dir/existing-file-with-changed-size-and-time-stamp.txt 
#    cd+++++++++ some/dir/new-directory/
#    .d....og... some/dir/existing-directory-with-changed-owner-and-group/
#    .d..t.og... some/dir/existing-directory-with-different-time-stamp/
#    ------------------------------------------------------
#    Explaination of each bit in the output:
#    YXcstpoguax  path/to/file
#    |||||||||||
#    ||||||||||`- x: The extended attribute information changed
#    |||||||||`-- a: The ACL information changed
#    ||||||||`--- u: The u slot is reserved for future use
#    |||||||`---- g: Group is different
#    ||||||`----- o: Owner is different
#    |||||`------ p: Permission are different
#    ||||`------- t: Modification time is different
#    |||`-------- s: Size is different
#    ||`--------- c: Different checksum (for regular files), or
#    ||              changed value (for symlinks, devices, and special files)
#    |`---------- the file type:
#    |            f: for a file,
#    |            d: for a directory,
#    |            L: for a symlink,
#    |            D: for a device,
#    |            S: for a special file (e.g. named sockets and fifos)
#    `----------- the type of update being done::
#                 <: file is being transferred to the remote host (sent)
#                 >: file is being transferred to the local host (received)
#                 c: local change/creation for the item, such as:
#                    - the creation of a directory
#                    - the changing of a symlink,
#                    - etc.
#                 h: the item is a hard link to another item (requires 
#                    --hard-links).
#                 .: the item is not being updated (though it might have
#                    attributes that are being modified)
#                 *: means that the rest of the itemized-output area contains
#                    a message (e.g. "deleting")
#    ------------------------------------------------------
# 5. To focus only on the changes that are substantive for each context (new
#    file, duplicate file, etc), the output produced by rsync --itemize-changes
#    is piped to sed to focus on items desired in each context.
# 6. For information on other rsync flags used check the manpage.
#

# set default values
change_count="0"    # nothing changed yet
ownership_changes="0"    # nothing yet
warning_count="0"    # nothing yet, fingers crossed
dirs_to_preserve=""    # nothing yet

# get the file/directory change list, as determined by rsync
full_file_list=$(rsync --archive --acls --xattrs --dry-run\
    --itemize-changes -vvv \
    "${SOURCEPATH}" \
    "${DESTINATIONPATH}" \
    | grep -E '^(\.|>|<|c|h|\*).......... .')

# level 2 verbose message, sent to file descriptor 4 
printf -- "==================\nRaw List:\n%s\n__________________\n\n" "${full_file_list}" >&4


#####################################################################
##### PREPARE CHANGE LIST ###########################################

# loop over each line in DIRSTOPRESERVEFILE and remove it from full_file_list
# as these are false positives, especially if we are applying ownership or 
# permission changes to the destination directories
while read -r line || [[ -n "${line}" ]]; do  # allows for last line with no newline
    # skip lines that are delimited as a comment (with #) or are blank
    if ! [[ "${line}" =~ ^[:space:]*# || "${line}" =~ ^[:space:]*$ ]]; then
        # using some bash fu, add a trailing slash if one is not already present
        line="${line}$(  printf \\$( printf '%03o' $(( $(printf '%d' "'${line:(-1)}") == 47 ? 0 : 47 )) )  )"

        # save this info as it is needed later during stale directory cleanup
        dirs_to_preserve="${dirs_to_preserve}${line}"$'\n'

        # make the path local; remove $SOURCEPATH from the beginning of $line
        # via the substring removal capacities of bash's parameter expansion
        local_path="${line#$SOURCEPATH}"
    
        # search for a match to $line in $full_file_list. if found, remove the matching line
        full_file_list=$(sed -r "\|^........... \.?${local_path}$|d" <<< "${full_file_list}")
    fi
done <"${DIRSTOPRESERVEFILE}"


# extra check to make sure ./ is removed as the previous loop will only have
# removed it if DIRSTOPRESERVEFILE contains an entry that is an exact match for
# the source path
full_file_list=$(echo "${full_file_list}" | sed '/^\s*$/d' | sed '/^........... \.\//d')

# get the count of items in full_file_list
full_list_count=$(echo "${full_file_list}" | sed '/^\s*$/d' | wc -l)

# level 2 verbose message, sent to file descriptor 4 
printf -- "==================\nItems to Process:\n%s\n__________________\n\n" "${full_file_list:- < none >}" >&4

# if something has changed, process it
if [ "${full_list_count}" -gt "0" ]; then

    # level 1 verbose message, sent to file descriptor 3 
    printf -- "\nFound (%s) additions or changes, starting processing now.\n" "${full_list_count}" >&3

    #####################################################################
    ##### PROCESS FILE SYSTEM CHANGES LIKE DIRECTORIES, LINKS, ETC ######

    # isolate any file system changes (directories, links, etc) excluding files
    # grep for anything not a file (.f) and grep for anything not an unchanged directory
    # unchanged directories are duplicates and will be removed later if empty
    structure_changes=$(echo "${full_file_list}" | grep -E --invert-match '^.f' | grep -E --invert-match '^\.d         ')
    structure_changes_count=$(echo "${structure_changes}" | sed '/^\s*$/d' | wc -l)
    
    # process any file system changes
    if [ "${structure_changes_count}" -gt "0" ]; then
        # level 1 verbose message, sent to file descriptor 3 
        printf -- "\n==================\nFound (%s) structure changes, starting processing now.\n" "${structure_changes_count}" >&3

        # level 2 verbose message, sent to file descriptor 4 
        printf -- "\nStructure Changes:\n%s\n\n" "${structure_changes}" >&4
    
        structure_changes_actual_count="0"    # nothing yet
        structure_changes_actual=""    # nothing yet
    
        IFS=" "    # set word break on space for splitting
    
        # read the input by line; split the line to extract rsync bits flags and path
        while read -r -d $'\n' bits path; do
    
            # Use rsync to populate directories, soflink, hardlink and other
            # associated attribute changes in the destination. rsync does not
            # remove source directories, those are cleaned up later.
        
            # via some bash fu, capture stdout, sterr and return code for rsync
            # ⬇ start of out-err-rtn capture fu
            eval "$({ cmd_err=$({ cmd_out="$( \
                rsync --itemize-changes --links --times \
                --group --owner --devices --specials --acls --xattrs \
                --remove-source-files  --files-from=- \
                --include='*/' --exclude='*' \
                "${SOURCEPATH}" "${DESTINATIONPATH}" \
                <<< "${path}" \
              )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
            # ⬆ close of out-err-rtn capture fu
    
            if [ "${cmd_ret}" -eq "0" ]; then
                logger "${bits}"$'\t'"\"${SOURCEPATH}${path}\""$'\t'"\"${DESTINATIONPATH}${path}\""
                # level 2 verbose message, sent to file descriptor 4
                printf -- "Changes (%s) were replcated from (%s) to the destination.\n" "${bits}" "${SOURCEPATH}${path}" >&4
    
                structure_changes_actual="${structure_changes_actual}${path}"$'\n'
                let structure_changes_actual_count+="1"
    
                let change_count+="1"
                ownership_changes="1"
            else
                logger "*warning***"$'\t'"Failed to replicate changes (${bits}) from (${SOURCEPATH}${path}) to the destination. [${cmd_ret} : ${cmd_err}]"
                # level 2 verbose message, sent to file descriptor 4
                printf -- "Warning: failed to replicate changes (%s) from (%s) to the destination. [%s : %s]\n" "${bits}" "${SOURCEPATH}${path}" "${cmd_ret}" "${cmd_err}" >&4
            fi
    
            #clean up reused vars
            unset cmd_out
            unset cmd_err
            unset cmd_ret
        done <<< "${structure_changes}"
        unset IFS
    
        # level 2 verbose message, sent to file descriptor 4
        printf -- "\nStructure changes were processed for the following:\n%s\n" "${structure_changes_actual}" >&4

        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n  Done processing (%s) needed structure changes.\n" "${structure_changes_actual_count}" >&3
    fi


    #####################################################################
    ##### PROCESS NEW FILES #############################################

    # isolate any files that are new
    new_files=$(echo "${full_file_list}" | grep -E '^>f\+\+\+\+\+\+\+\+\+' | sed 's/^........... //g')
    new_count=$(echo "${new_files}" | sed '/^\s*$/d' | wc -l)

    # process any new files
    if [ "${new_count}" -gt "0" ]; then
        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n==================\nFound (%s) new files, starting processing now.\n" "${new_count}" >&3

        # level 2 verbose message, sent to file descriptor 4
        printf -- "\nNew Files:\n%s\n\n" "${new_files}" >&4

        IFS=$'\n'    # make newline the only separator
        for path in ${new_files}; do
            # move the file; --no-clobber is used to ensure fail safe function.
            # If the file fails to move because of a collision, this is very
            # important to catch and not overwrite any file. This would
            # indicate that a rare boundary case has manifest itself. In that
            # case, leave the file in the sourc directory as it is best handled
            # on a later run of the script. 


            # via some bash fu, capture stdout, sterr and return code for mv
            # ⬇ start of out-err-rtn capture fu
            eval "$({ cmd_err=$({ cmd_out="$( \
                mv --no-clobber "${SOURCEPATH}${path}" "${DESTINATIONPATH}${path}" \
              )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
            # ⬆ close of out-err-rtn capture fu

            if [ "${cmd_ret}" -eq "0" ]; then
                logger ">f+++++++++"$'\t'"\"${SOURCEPATH}${path}\""$'\t'"\"${DESTINATIONPATH}${path}\""
                # level 2 verbose message, sent to file descriptor 4
                printf -- "File (%s) was moved from source to destination directory.\n" "${path}" >&4

                let change_count+="1"
                ownership_changes="1"
            else
                logger "*warning***"$'\t'"failed to move file (${SOURCEPATH}${path}) to the destination. [${cmd_ret} : ${cmd_err}]"
                # level 2 verbose message, sent to file descriptor 4
                printf -- "Warning: File (%s) failed to move from source to destination directory. [%s : %s]\n" "${path}" "${cmd_ret}" "${cmd_err}" >&4
            fi
        done
        unset IFS    # good practice to reset IFS to its default value

        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n  Done processing new files.\n" >&3
    fi


    #####################################################################
    ##### PROCESS SIMILAR (SAME NAME, DIFFERENT CONTENT) FILES ##########

    # isolate any potential file collisions
    offending_files=$(echo "${full_file_list}" | grep -E '^>f.s|>f..t')
    offending_count=$(echo "${offending_files}" | sed '/^\s*$/d' | wc -l)
    
    # process any file name collisions
    if [ "${offending_count}" -gt "0" ]; then
        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n==================\nFound (%s) files collisions (same name, different content), starting processing now.\n" "${offending_count}" >&3

        # level 2 verbose message, sent to file descriptor 4
        printf -- "\nFile Collisions:\n%s\n\n" "${offending_files}" >&4

        offending_files_actual_count="0"    # nothing yet
        offending_files_actual=""    # nothing yet
        
        IFS=" "    # set word break on space for splitting

        # read the input by line; split the line to extract rsync bits flags and path
        while read -r -d $'\n' bits path; do
            unique_path=$(make_filename_unique "${path}")

            # move the file while renaming it to its new unique name;
            # --no-clobber is used to ensure fail safe handling of the file
            # to the destination directory.

            # via some bash fu, capture stdout, sterr and return code for mv
            # ⬇ start of out-err-rtn capture fu
            eval "$({ cmd_err=$({ cmd_out="$( \
                mv --no-clobber "${SOURCEPATH}${path}" "${DESTINATIONPATH}${unique_path}" \
              )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
            # ⬆ close of out-err-rtn capture fu

            if [ "${cmd_ret}" -eq "0" ]; then
                logger "${bits}"$'\t'"\"${SOURCEPATH}${path}\""$'\t'"\"${DESTINATIONPATH}${unique_path}\""
                # level 2 verbose message, sent to file descriptor 4
                printf -- "File (%s) was moved from source to destination directory with deconflicted name (%s).\n" "${SOURCEPATH}${path}" "${SOURCEPATH}${unique_path}" >&4

                offending_files_actual="${offending_files_actual}${path}\n"
                let offending_files_actual_count+="1" 

                let change_count+="1"
                ownership_changes="1"

            else
                logger "*warning***"$'\t'"Failed to move file (${SOURCEPATH}${path}) to destination directory with deconflicted name (${SOURCEPATH}${unique_path}). [${cmd_ret} : ${cmd_err}]"
                # level 2 verbose message, sent to file descriptor 4
                printf -- "Warning: failed to move file (%s) to destination directory with deconflicted name (%s). [%s : %s]\n" "${SOURCEPATH}${path}" "${SOURCEPATH}${unique_path}" "${cmd_ret}" "${cmd_err}" >&4
            fi

            #clean up reused vars
            unset cmd_out
            unset cmd_err
            unset cmd_ret
        done <<< "${offending_files}"
        unset IFS

        # level 2 verbose message, sent to file descriptor 4
        printf -- "\nFile collisions were processed via renaming for the following:\n%s\n" "${offending_files_actual}" >&4
        
        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n  Done processing (%s) file collisions by renaming offending files.\n" "${offending_files_actual_count}" >&3
    fi


    #####################################################################
    ##### PROCESS DUPLICATE (SAME NAME, SAME CONTENT) FILES #############

    # isolate files that are potential duplicates of existing files
    same_files=$(echo "${full_file_list}" | grep -E '^\.f')
    same_count=$(echo "${same_files}" | sed '/^\s*$/d' | wc -l)

    # process any unchanged files
    # as an extra measure of precaution, verify each file again for sameness directly before deletion
    if [ "${same_count}" -gt "0" ]; then
        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n==================\nFound (%s) duplicate (same name, same content) files, starting processing now.\n" "${same_count}" >&3

        # level 2 verbose message, sent to file descriptor 4
        printf -- "\nDuplicate Files:\n%s\n\n" "${same_files}" >&4

        same_files_actual_count="0"    # nothing yet
        same_files_actual=""    # nothing yet

        IFS=" "    # set word break on space for splitting
    
        # read the input by line; split the line to extract rsync bits flags and path
        while read -r -d $'\n' bits path; do

            # In the spirit of failing safe, we validate the full contents of
            # file via checksum hash before proceeding with deletion.
            checksum_match=$(rsync --checksum --archive --acls --xattrs --dry-run -vvv --whole-file \
                "${SOURCEPATH}${path}" "${DESTINATIONPATH}${path}" | grep -c "uptodate")

            # If the checksum of the destination file matched the source file,
            # delete the source file as it is an exact duplicate.
            if [ "${checksum_match}" -eq "1" ]; then

                # via some bash fu, capture stdout, sterr and return code for rsync
                # ⬇ start of out-err-rtn capture fu
                eval "$({ cmd_err=$({ cmd_out="$( \
                    rm --force "${SOURCEPATH}${path}" \
                  )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
                # ⬆ close of out-err-rtn capture fu

                if [ "${cmd_ret}" -eq "0" ]; then
                    logger "${bits}"$'\t'"\"${SOURCEPATH}${path}\""$'\t'"\"${DESTINATIONPATH}${path}\""
                    # level 2 verbose message, sent to file descriptor 4
                    printf -- "File (%s) was a confirmed duplicate via checksum, so it was deleted from the source directory.\n" "${SOURCEPATH}${path}" >&4

                    same_files_actual="${same_files_actual}${path}\n"
                    let same_files_actual_count+="1"

                    let change_count+="1"
                    ownership_changes="1"
                else
                    logger "*warning***"$'\t'"File (${SOURCEPATH}${path}) was confirmed duplicate via checksum; attempts to delete file from source directory have failed. [${cmd_ret} : ${cmd_err}]"
                    # level 2 verbose message, sent to file descriptor 4
                    printf -- "Warning: File (%s) was confirmed duplicate via checksum; attempts to delete file from source directory have failed. [%s : %s]\n" "${SOURCEPATH}${path}" "${cmd_ret}" "${cmd_err}" >&4
                fi
                
            else
            # If the checksum of the destination file did not matched the
            # source file, the source file is a different file, despite its
            # name being the same. To safely move the file, make the filename
            # unique, then move the file.

                unique_path=$(make_filename_unique "${path}")

                # move the file while renaming it to its new unique name
                # --no-clobber is again used to ensure fail safe mode

                # via some bash fu, capture stdout, sterr and return code for rsync
                # ⬇ start of out-err-rtn capture fu
                eval "$({ cmd_err=$({ cmd_out="$( \
                    mv --no-clobber "${SOURCEPATH}${path}" "${DESTINATIONPATH}${unique_path}" \
                  )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
                # ⬆ close of out-err-rtn capture fu

                if [ "${cmd_ret}" -eq "0" ]; then
                    logger "${bits}"$'\t'"\"${SOURCEPATH}${path}\""$'\t'"\"${DESTINATIONPATH}${unique_path}\""
                    # level 2 verbose message, sent to file descriptor 4
                    printf -- "File (%s) was suspected a duplicate but instead was confirmed CHANGED, so it was moved from source to destination directory with deconflicted name (%s).\n" "${SOURCEPATH}${path}" "${SOURCEPATH}${unique_path}" >&4
                    
                    same_files_actual="${same_files_actual}${path}\n"
                    let same_files_actual_count+="1"

                    let change_count+="1"
                    ownership_changes="1"
                else
                    logger "*warning***"$'\t'"File (${SOURCEPATH}${path}) was suspected a duplicate but instead was confirmed CHANGED; failed to move it to the destination directory with deconflicted name (${SOURCEPATH}${unique_path}). [${cmd_ret} : ${cmd_err}]"
                    # level 2 verbose message, sent to file descriptor 4
                    printf -- "Warning: File (%s) was confirmed duplicate via checksum; failed to move it to the destination directory with deconflicted name (%s). [%s : %s]\n" "${SOURCEPATH}${path}" "${SOURCEPATH}${unique_path}" "${cmd_ret}" "${cmd_err}" >&4
                fi          
            fi
            
            #clean up reused vars
            unset cmd_out
            unset cmd_err
            unset cmd_ret
        done <<< "${structure_changes}"
        unset IFS

        # level 1 verbose message, sent to file descriptor 3
        printf -- "\n  Done processing duplicate files.\n" >&3
    fi
fi



# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
# tl;dr: Delete stale subdirectories from the source directory.
#
# The details:
# 1. The find command is used to identify directories whose create time is
#    older than 15 minutes. The 15 minute grace period is intended to allow 
#    people time to create a directory and move files to it without it being
#    deleted out from under them. The default age of 15 minutes can be
#    changed via the --minutes-until-stale (or -ms for short).
# 2. The directories found are redirected to a while loop for individual
#    processing.
# 3. $dirs_to_preserve is populated above from the config file indicated via
#    the --preserve (or -p for short) flag for this script.
# 4. Grouping parenthesis and an exclaimation point are used to negate the 
#    affirmative return code from grep.
# 5. Grep searches for the directory path from match_dir in dirs_to_preserve.
#    If a match is found in the file, it should be preserved, thus the
#    preceeding boolean negation is needed. If the path is not found the
#    negation makes the return result true.
# 6. If true, rmdir (remove dir) command is executed against the match_dir. 
#    We expect the directories to be empty at this point but we don't control
#    what users or other applications might do, so we have to account for files
#    being added to the directory outside of our control. There is a fail-safe
#    mechanism in the fact that rmdir is designed to fail if the directory is
#    not empty.

# level 1 verbose message, sent to file descriptor 3
printf -- "\n==================\nChecking for any stale (older than %s mins) directories in the source path.\n\n" "${MINSUNTILSTALE}" >&3

dir_cleanup_count="0" # nothing yet

# using process substitution, feed the find stout to while's stdin
while IFS= read -r -d $'\0' line; do
    # if there is not a trailing slash, add one via some bash fu
    match_dir="${line}$( printf \\$( printf '%03o' $(( $(printf '%d' "'${line:(-1)}") == 47 ? 0 : 47 )) ) )"

    # Check to see if the dirs_to_preserve was populated. If so, verify that
    # match_dir is not listed in dirs_to_preserve
    if [ -n "${dirs_to_preserve}" ] &&  !  grep -xq "${match_dir}" <<< "${dirs_to_preserve}"; then

        # via some bash fu, capture stdout, sterr and return code for rsync
        # ⬇ start of out-err-rtn capture fu
        eval "$({ cmd_err=$({ cmd_out="$( \
            rmdir "${line}" 2> /dev/null \
          )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
        # ⬆ close of out-err-rtn capture fu
        
        if [ "${cmd_ret}" -eq "0" ]; then
            logger "*deleting**"$'\t'"\"${SOURCEPATH}${path}\""
            # level 2 verbose message, sent to file descriptor 4
            printf -- "Directory (%s) was deleted from the source directory.\n" "${match_dir}">&4

            let change_count+="1"
            let dir_cleanup_count+="1"
        else
            logger "*warning***"$'\t'"failed to delete directory (${SOURCEPATH}${match_dir}) from source directory. [${cmd_ret} : ${cmd_err}]"
            # level 1 verbose message, sent to file descriptor 3
            printf -- "Attempted to delete directory (%s) but failed to do so. [%s : %s]\n" "${match_dir}" "${cmd_ret}" "${cmd_err}" >&3
        fi
    else
        # level 2 verbose message, sent to file descriptor 4
        printf -- "Directory (%s) is stale but was preserved in the source directory.\n" "${match_dir}" >&4
    fi
done < <(find "${SOURCEPATH}" -type d -cmin "+${MINSUNTILSTALE}" -print0)

# level 1 verbose message, sent to file descriptor 3
printf -- "\n  Done processing (%s) stale directories.\n" "${dir_cleanup_count}" >&3



# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
# tl:dr: If substantive file system changes were made, verify ownership.
#
# The details:
# 1. If rsync 3.1.0+ were available we could use the --chown flag, but since
#    it cannot be counted upon, a more structured aproach will be taken. Thus,
#    the iterative use of chown as prescribed by in the ownership file. The
#    ownership file is set via the flag --ownership (of -o for short).
# 2. The chown commands are only needed if files were moved by rsync therefore
#    the if statement, which checks to see if the change_count is greater than
#    zero.

# loop over each line in OWNERSHIPFILE and enforce the ownership supplied
if [ "${ownership_changes}" -gt "0" ]; then
    # level 1 verbose message, sent to file descriptor 3
    printf -- "\n==================\nChanges require us to validate ownership.\n\n" >&3

    while read -r line || [[ -n "${line}" ]]; do  # allows for last line with no newline
        # skip lines that are delimited as a comment (with #) or are blank
        if ! [[ "${line}" =~ ^[:space:]*# || "${line}" =~ ^[:space:]*$ ]]; then
            
            # split the line on tab to extract ownership info from dir path
            while read -r a b;do perm="$a"; path="$b"; done <<<"$line"

            # if both the owner:group ($perm) and the path ($path) are supplied
            if [ -n "${perm}" ] && [ -n "${path}" ]; then

                # check if the path supplied is really a directory
                if [ -d "${path}" ]; then
                    # validate that any symlinks in the paths resolved
                    realpath="$(readlink -f "${path}")"
                    realdest="$(readlink -f "${DESTINATIONPATH}")"

                    # make sure that the $line is local to destination path
                    if [ "$(echo "${realpath}" | grep -E -c "^${realdest}")" = "1" ]; then
                    
                        # As required by chown, make sure the path does not end
                        # in a slash. sed is used to make sure that multiple 
                        # slashes at the end are removed if they exist.
                        realpath="$(echo "${realpath}" | sed -r 's/\/+$//')"
                        
                        # no-dereference is used to keep chown from following links

                        # via some bash fu, capture stdout, sterr and return code for rsync
                        # ⬇ start of out-err-rtn capture fu
                        eval "$({ cmd_err=$({ cmd_out="$( \
                            chown --recursive --preserve-root --silent --no-dereference "${perm}" "${realpath}" \
                          )"; cmd_ret=$?; } 2>&1; declare -p cmd_out cmd_ret >&2); declare -p cmd_err; } 2>&1)"
                        # ⬆ close of out-err-rtn capture fu
                        
                        if [ "${cmd_ret}" -eq "0" ]; then
                            # level 2 verbose message, sent to file descriptor 4
                            printf -- "Directory path (%s) had ownsership (%s) applied.\n" "${path}" "${perm}" >&4
                        else
                            # level 2 verbose message, sent to file descriptor 4
                            printf -- "Warning: attempt to set directory path (%s) with ownership (%s) failed. [%s : %s]\n" "${path}" "${perm}" "${cmd_ret}" "${cmd_err}" >&4
                        fi  
                    else
                        # level 2 verbose message, sent to file descriptor 4
                        printf -- "Directory (%s) is not local to the destination directory; ignoring it.\n" "${path}" >&4
                    fi
                else
                    # level 2 verbose message, sent to file descriptor 4
                    printf -- "Directory (%s) listed in ownership file is not a directory; ignoring it.\n" "${path}" >&4
                fi
            else
                # level 2 verbose message, sent to file descriptor 4
                printf -- "The line (%s) in ownership file does not follow the required pattern; ignoring it.\n" "${line}" >&4
            fi

        fi
    done <"${OWNERSHIPFILE}"
    printf -- '\n==================\nMade (%s) total changes. ' "${change_count}"
else
    printf -- '\nNo (%s) changes. ' "${change_count}"
fi

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
#
# tl;dr: tidy up and close out

# because we're cautious like that, we'll close the file descriptors we used for our verbose output
for level in $(seq 3 "${VERBOSELEVEL}"); do
    (( "${level}" <= "${VERBOSITYMAX}" )) && eval exec "${level}>&-"
done

printf -- "\nAll done.\n"
exit 0