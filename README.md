# movestough.sh


**tl;dr: Bash script to monitor a source directory and move any added objects to a target directory, ensuring via fail-safe handling of data and then clean up the source directory as directed. Log all actions.**  


## Intended Use  
The principal use of this script is to move files from a source directory to a target directory, on the same filesystem, via fail-safe handling.

For more background information, usage suggestions and the latest version of this script, please visit: https://github.com/jmmitchell/movestough


**Strengths over alternative options:**  
For those more familiar with linux cli handiwork, you can think of this script as the best of `rsyc`, `find`, `mv`, `mkdir` & `rmdir` rolled into one.

This script excels in comparison to using `rsync` or `mv` alone in that it provides finer-grained handling of the move process.

While there may be faster or less complicted ways to simply move some files, this script has been crafted to err on the side of data preservation and to produce an audit trail for all actions taken.

To expand upon that, a few of the distinctive features are:

(1) Every create/update/delete action can be logged in a timestamped log. The `mv` command does not do this and `rsync`, without some serious canjoling, omits key actions from it's output and therefore leaves you with no record.

(2) The directory structure on the source filesystem can be cleaned up once they are empty. Specifically, after moving the source files to their target, if there empty directories on the source filesystem they can be deleted after a specified delay or they can be selectively preserved. The ability to clean up the empty source subdirectories after moving the files conatined within is a feature that is sorely missing from `rsync`.

(4) Directories that are targeted for deletion as part of the clean up process will not be deleted if they, for unforseen reasons, are not empty when we attempt to deleted them. This may seem obvious but is a subtle use-case that can easily manifest itself if this script is used on a computer where files are being added by other local processes (e.g. dropbox) or has a shared filesystem where network users may be actively creating new files in the same directory structure in which we are working.

(3) Any attempt to move a file is done with the greatest care for data preservation. As an example, a file that appears to be a duplicate, by file name conflict, should be examined closely before any potentially destructive action is taken. Files that are suspected to be duplicates are validated by a hash function. If the source file (file to be moved) is found to be a byte-for-byte duplicate of the existing target (i.e. destination) file, the source file is not copied and be safely disregarded. If on the other hand, the source file is found to have the same name as the existing target file but contains different data it will be moved but will be given a unique filename so as to preserved the data and allow a person to manually inspect both files after the fact and to make a judgement call on what to keep.


**Feature summary:**  

- empty directories cleaned up from source directory (`rsync` does not do this)
- via optional config, source subdirectories can be selectively preserved
- consistent timestamped logging of all create/update/delete actions
- log all items removed from the source directory (`rsync` does not do this)
- logs level can specified to record increasing levels of detail
- warging messages in logs include stderr and return code of failed command
- two levels of verbose output are available when when run interactively
- target directory structure will be created, if needed
- via optional config file, new ownership rules can be specified for items moved to the target directory
- each potential file collisions (files with the same name & date) are verified via checksum of both source and target files
- verified file collisions are moved to the target via deconflicted filename as opposed to `rsync` delta copy that might replicate a partial written file
- exact duplicate files, verified via checksum, are not replicated
- if source and target are on the same filesystem, files are "moved" super fast via metadata update (directory entries) rather than reading and rewriting file contents
- file-level atomic moves ensuring there is never a partially moved file


**Shout-outs:**  

> If I have seen further than others, it is by standing upon the shoulders of giants.  
> - Isaac Newton
		
There are many nameless people who have unselfishly contributed their time to help share their enthusiasm for and knowledge about solving problems via software development. There are not enough words to properly thank each. There are also some notably brilliant minds who had creative solutions to challenges that were faced in wrangling bash into doing what was needed in this script. References to their contributions are included below for your further reference and enjoyment:  

- [handling of various levels of verbose output via file descriptors](http://stackoverflow.com/a/20942015/171475)  
- [capturing stderr, stdout, return code from a command executed in a subshell](http://stackoverflow.com/a/26827443/171475)


**WARNING**  
It should be recognized that while this script makes every attempt to fail safely, there are most probably edge cases that are not accounted for, so proceed with caution, question everything and, if you find bugs please contribute back with a pull request. You have been warned.


**LICENSE**  
This software is licensed using the MIT License

Copyright (c) 2016 John Mark Mitchell

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.




##The Details

1. Using rsync, look in the source directory for files, directories and links that need to be moved to the destination directory.
2. Using rsync, replicate the identified structural items (folders & links) to the destination directory, applying attribute changes as needed to mirror the source. Once replicated, rsync will remove the source items. An exception to this is subdirectories. These are handled last.
3. For completely new files found in the source directory, move them via the mv command.
4. Manage any possible file collisions by making offending source file names unique before moving them to the target directory. The the collision-free change list is fed to mv to complete the move from source to destination.
5. For files that appear exactly the same (size, attributes and change date) in the source and destination, check each via hash against the matching destination file. If the hashes match, there is no need to mv the file, so the source file is deleted. Else, move the file via unique file name. Uniqueness style can be specified via the `--unique-style` (or `-u` for short).
6. If changes were made in the destination directory, check the supplied ownership config file and reinforce ownership as indicated.
7. Look for stale, empty directories in the source directory and remove them. Staleness is determined by the change date as compared to the number of minutes passed into the flag `--minutes-until-stale` (or `-ms` for short). If no flag value is set, staleness defaults to 15 mins.
   
**Dependencies**  

- linux - versions / flavors??
- bash and builtins (declare, echo, let, local, printf, read)
- external dependencies
	- mkdir  
	- rsync  
	- mv  



##Usage
The script accepts arguments via the following flags:
    
> **`-s=` or `--source=`**  
REQUIRED. Source directory path. Should be a path to the source directory to inspect for new file system changes that will be moved to the target directory. The argument passed can be a symbolic link to the intended source directory.
 	
> **`-d=` or `--destination=`**  
REQUIRED. Destination directory path. Should be a path to the target directory to which source directory additions will be added. The argument passed can be a symbolic link to the intended destination directory.

   
> **`-p=` or `--preserve=`**  
Directories to preserve config file. Parameter should be the path to file that contains directives about source subdirectories to perserve from the stale directory clean up process.

> **`-o=` or `--ownership=`**  
Ownership config file. Parameter should be the path to file that contains file ownership and group permissions to enforce on the files and subdirectories of the target path.    
    	
> **`-l=` or `--log=`**  
Log File. Parameter should be the path to file where the script should log changes.
    	
> **`-ms=` or `--minutes-until-stale=`**  
Minutes until directories are stale. Parameter should be a whole number. After files are moved from the source directory to the target directory, the subdirectories of the source directory left in tact for a set period of time. By default that is 15 minutes. The number supplied as the parameter can override the defualt behavior.
    	
> **`-u=` or `--unique-style=`**  
Syle to use when renaming files. Source files that are conflicting (same name but different content) with files in the target directory are made unique so that they can be moved to the target directory via one of the following styles:  
>> `1` : style 1, unique string is inserted at the last period found in the filename  
>> `2` : style 2, unique string is inserted at the first period of the filename  
>> < default >: if no a unique string is appended to the end of the file name  

> **`-v=` or `--verbose=`**  
Verboseness level of the interactive output. Options are:  
>> `1` : basic information for each major file type  
>> `2` : detailed information about each action taken  

**CLI**  
To run the script only two parameters are required:  
1. source directory path (via `-s` or `--source`), and  
2. destination directory path (via `-d` or `--destination`)

An example of how the script might be typically used:

	/my/scripts/movestough.sh \
		-s=/incoming/pictures/ \
		-d="/media/pictures/to be processed/" \
		-p=/my/scripts/movestough-scaffolding.conf \
		-o=/my/scripts/movestough-ownership.conf \
		-l=/var/log/movestough.log \
		-v=2 \
		-u=1

**Cron**  
To run the script in an automated, unattended manor, the preferred method is via `cron`. 
First, if you are unfamilar with `cron`, [read the cron man page](http://linux.die.net/man/5/crontab). It is important to use `flock` when running this script from a crontab. More details on `flock` can be found on its [the flock man page](http://linux.die.net/man/2/flock).
This allows the script to be executed often but keeps the system from having
simultaneous copies of the script running. Not only is this resource (CPU, RAM) friendly, this eliminates race conditions and other nasty unintendedside effects.

A suggested crontab entry to run the script every 3 minutes with same configuration as the CLI example above would look something like:


	*/3 * * * * /usr/bin/flock -w 0 -n /var/lock/movestough.lock /my/scripts/movestough.sh -s=/incoming/pictures/ -d="/media/pictures/to be processed/" -p=/my/scripts/movestough-scaffolding.conf -o=/my/scripts/movestough-ownership.conf -l=/var/log/movestough.log -u=1
	
It is unfortunate that crontab entries have no means of commenting or multiline configuration. To be accurate, the above entry is displayed as a single line as it would need to be in your crontab. If you want to understand the details of the example crontab entry, it is recommended that you copy the contents above to a text editor where you can enable line wrapping or temporarily insert white space to better visualize the contents.

If you expect to use the script in an unattended manor for an extended period of time, consider using `logrotate` to manage your logs so they do not grow indefinitely. If you are unfamiliar with `logrotate`, [read the logrotate man page](http://linux.die.net/man/8/logrotate). An example config for `logrotate` might look something like: 

	/var/log/movestough*.log {
        size 10M
        weekly
        rotate 12
        maxage 90
        compress
        missingok
        copytruncate
	}



##History
**changelog:**  

 2016-05-04 no change; verified that source or target directory arguments can be a symbolic link to a directory and the script functions properly on fronts  
 2016-05-04 no change; verified that `if [ -d "/dev/null" ]` fails which keeps it from erroneously being supplied as the source or target directory  
 2016-04-28 added checks to `make\_filename\_unique` function to account for file names that don't have a period or an extension  
 2016-04-28 fix display of verbose level number on interactive run  
 2016-04-27 fixed error where `--ownership` was assumed active even if it was not specified  
 2016-04-26 fixed error where `--preserve` was assumed active even if it was not specified  
 2016-04-25 corrected verbose output messages for file collision processing
 2016-04-24 improved `make\_filename\_unique` function allowing a style number to be specified via a `-unique-style=` (or `-u=` for short) flag  
  2016-04-23 just in case it was not specified in a via a `--preserve=` (or `-p` for short) config file, the source directory is preserved during the stale directory clean up process  
 2016-04-23 updated docs and comments to prepare for github  
 2016-04-20 added basic exit codes  
 2016-04-18 changed verbose output from notify function to use file descriptors (allows safe handling of all chars in output)  
 2016-04-17 fixed use of vars in `printf` statements; example: `printf "Hello, %s\n" "$NAME"`  
 2016-04-16 standardized log file output mimicking `rsync` bit flag output  
 2015-04-15 added `cmd\_out`, `cmd\_err`, `cmd\_rtn` fu to each `rsync`, `mv`, `rmdir` command  
 2016-04-10 fixed nasty bug in stale dir check introduced by file checks  
 2016-04-09 optimized flag checks and added file exist/write checks  
 2016-04-07 fixed egregious bug with rsync use (missing `--dry-run`)
 2016-04-05 add destination file ownership via a conf file  
 2016-04-05 add verbose level2 checking for errors of file mv commands  
 2016-04-04 add handling of commented lines, as delimited by the # symbol, in the input config files  
 2016-04-03 add levels of verboseness to stdout  
 2016-04-02 standardize verbose output to stdout in function  
 2016-03-30 add args for source and destination directories  
 2016-03-29 allow directories to be preserved in source via conf file  
 2016-03-27 rewrite to use rsync to only list changes (fixes overwrites)  
 2016-12-02 updated README.md and comments to clarify intended uses and distictive features of this script over traditional alternative like using `rsync` or `mv` alone  


**backlog in no particular order:**  


- verify what happens if source and target are the same  
- create a help function triggered by checking and `--help` or `-?` 
- implement check on success of rsync when creating the checksum_match
- add some checking for dependencies and minimum versions of bash, rsync, etc.; once discovered, this should also be added to the documentation as well in the dependencies section of the README
- add the ability for the script to be run with prompts for required parameters 
- add the ability to daemonize the script
- implement an internal list of files or directory changes and narrow the use of chown to only those
- consider the use of `trap` to ensure consistent state when forced to exit
- clean up out and make it more uniform between versions of verboseness
- for efficiency, the structure changes loop should ignore owner and group differences because we very well might be enforcing the variance; this manifests itself when directories are not in the scaffolding to keep but have yet to be marked as stale
- consider use of echo `-n` or `<<<` to suppress newlines or eliminate piped sed
- verify proper use of `[[ ]]` as opposed to `[ ]` in if statements
- consider convering `[[ ]]` to `(( ))` when the comparison is numerical (as opposed to string comparison)
- periodically test and check notices from http://www.shellcheck.net/
- implement check on success of `rsync` in hash check
- add different deconflicting options, like keeping file extension in tact
- add levels of verboseness levels to logging
- test links following behavior
- test moving of links, esp in light of: `--include='\*/' --exclude='\*'`
- test chown ownership of links see: `--no-dereference` flag in man page
- consider grouping piped sed and grep to one: `sed -e 'pattern 1' -e 'pattern 2'`
- implement use of warning_count and output even if not verbose or on sterr
- create option to inherit default ownership of receiving dir
- create option to inherit default permissions of receiving dir
- create a default ownership/permission behavior to change the files/directories that were changed
- if `mv --no-clobber` fails, see if it can be determined if collision, add to collision list
- check the difference in `rsync --perms --owner --group` and `--acls`
- add a feature to let files inherit the ownership from parent directory via: chown -R `stat . -c %u:%g` *
- at present files are filtered for ^>f.s|>f..t therefore attribute changes would be ignored, change to accommodate other changes
- add a `--dry-run` feature
- verify that the `rm --force` is not able to delete open, partially written files.







	