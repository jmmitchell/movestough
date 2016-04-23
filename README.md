# movestough.sh


**tl;dr: Move files in a source directory to a target directory without loss, then clean up the source directory as needed.**  


## Intended Use  
The primary function of this script is to move files from a source directory to
a target directory, on the same filesystem, via fail-safe handling.

**Strengths over alternative options:**  
This script is intended to provide fine-grained handling when moving filesystem
contents as compared to other alternatives, like rsync or mv alone.
While there may be faster or less complicated ways to move files, this script
has been specifically crafted to err on the side of data preservation and 
tracking every create/update/delete action in a timestamped log. For instance, this means 
that files should never be overwritten; sameness is verified by checksum 
of the file; directories that are marked for deletion will fail to be deleted
if they, for unforeseen reasons, are not empty.

For those more familiar with linux cli handiwork, think of this script as
the best of rsync, find, mv, mkdir and rmdir rolled into one.


**Key features:**  

- directories cleaned up from source directory (rsync does not do this)
- via optional config file, source subdirectories can be selectively preserved
- consistent timestamped logging of all create/update/delete actions
- logging of all items removed from source (not found in rsync)
- warning messages in logs capture error information
- warning messages in logs include stderr and return code of failed command
- two levels of verbose message when run interactively
- target directory structure will be created, if needed
- via optional config file, ownership rules can be specified for items 
  moved to the target directory
- each potential file collisions (files with the same name & date) are
  verified via checksum of both source and target files
- verified file collisions are moved to the target via deconflicted filename
  as opposed to rsync delta copy that might replicate a partial written file
- exact duplicate files, verified via checksum, are not replicated
- if source and target on the same filesystem, files are "moved" super fast
  via meta date update (directory entries) rather than file contents
- file-level atomic move so that there should never be a partially moved file

**Shout-outs:**  

> If I have seen further than others, it is by standing upon the shoulders of giants.  
> - Isaac Newton
		
There are many nameless people who have unselfishly contributed their time to help to share their enthusiasm for and knowledge about solving problems via software development. There are not enough words to properly thank each. There are also some notably brilliant minds who had creative solutions to challenges that were faced in wrangling bash into doing what was needed in this script. References to their contributions are included below for your further reference and enjoyment:  

- [handling of various levels of verbose output via file descriptors](http://stackoverflow.com/a/20942015/171475)  
- [capturing stderr, stdout, return code from a command executed in a subshell](http://stackoverflow.com/a/26827443/171475)

**WARNING**  
It should be recognized that while this script makes every attempt to fail
safely, there are most probably edge cases that are not accounted for, so
proceed with caution, question everything and, if you find bugs please
contribute back with a pull request. You have been warned.

**LICENSE**  
This software is licensed using the MIT License

Copyright (c) 2016 John Mark Mitchell

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.




##The Details

1. Using rsync, look in the source directory for files, directories and links
   that need to be moved to the destination directory.
2. Using rsync, replicate the identified structural items (folders & links)
   to the destination directory, applying attribute changes as needed to
   mirror the source. Once replicated, rsync will remove the source items. An
   exception to this is subdirectories. These are handled last.
3. For completely new files found in the source directory, move them via the
   mv command.
4. Manage any possible file collisions by making offending source file names
   unique before moving them to the target directory. The the collision-free
   change list is fed to mv to complete the move from source to destination.
5. For files that appear exactly the same (size, attributes and change date)
   in the source and destination, check each via hash against the matching
   destination file. If the hashes match, there is no need to mv the file, so
   the source file is deleted. Else, move the file via unique file name.
6. If changes were made in the destination directory, check the supplied
   ownership config file and reinforce ownership as indicated.
7. Look for stale, empty directories in the source directory and remove them.
   Staleness is determined by the change date as compared to the number of
   minutes passed into the flag --minutes-until-stale (or -ms for short). If
   no flag is set, staleness defaults to 15 mins.
   
**Dependencies**  

- linux - versions / flavors??
- bash and builtins (declare, echo, let, local, printf, read)
- external dependencies
	- mkdir  
	- rsync  
	- mv  



##Usage
**CLI**  
To run the script in an interactive manor, follow the example below:

	./movestough.sh \
		-s=/incoming/pictures/ \
		-d=/media/pictures/to be processed/ \
		-p=~/movestough-pictures-scaffolding.conf \
		-o=~/movestough-pictures-permissions.conf \
		-l=~/movestough-pictures.log
		-v=2

**Cron**  
First, if you are unfamilar with `cron`, [read the cron man page](http://linux.die.net/man/5/crontab). It is important to use `flock` when running this script from a crontab. More details on `flock` can be found on its [the flock man page](http://linux.die.net/man/2/flock).
This allows the script to be executed often but keeps the system from having
simultaneous copies of the script running. Not only is this resource (CPU, 
RAM) friendly, this eliminates race conditions and other nasty unintended
side effects.

With that said, a suggest crontab entry to run the script every
3 minutes would look something like:

	*/3 * * * * /usr/bin/flock -w 0 -n /Dropbox/Scripts/movestough-pictures.lock /Dropbox/Scripts/movestough.sh  -s=/Dropbox/Move\ to\ ReadyNAS/Pictures/ -d=/media/Pictures/~dropbox\ -\ to\ be\ sorted/ -p=/Dropbox/Scripts/movestough-pictures-scaffolding.conf -o=/Dropbox/Scripts/movestough-pictures-permissions.conf -l=/Dropbox/Scripts/movestough-pictures.log*/2 * * * * flock -w 0 -n /some/path/script.lock /some/path/script.sh ...

You will need to specify additional required flags like -s -d and maybe even
consider some optional but common flags, like -s or -p for the example above.

If you expect to use the script for an extended period of time, consider using `logrotate` to manage your logs so they grow indefinitely. If you are unfamiliar with `logrotate`, [read the logrotate man page](http://linux.die.net/man/8/logrotate). An config for `logrotate` might look something like: 

	/Dropbox/Scripts/movestough*.log {
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
 2016-04-23 updated docs and comments to prepare for github  
 2016-04-18 changed verbose output from notify function to use file descriptors (allows safe handling of all chars in output)  
 2016-04-17 fixed use of vars in printf statements; example: printf "Hello, %s\n" "$NAME"  
 2016-04-16 standardized log file output mimicking rsync bit flag output  
 2015-04-15 added cmd_out, cmd_err, cmd_rtn fu to each rsync, mv, rmdir  
 2016-04-10 fixed nasty bug in stale dir check introduced by file checks  
 2016-04-09 optimized flag checks and added file exist/write checks  
 2016-04-07 fixed egregious bug with rsync use (missing --dry-run)!!  
 2016-04-05 add destination file ownership via a conf file  
 2016-04-05 add verbose level2 checking for errors of file mv commands  
 2016-04-04 add handling of # comments in the input config files  
 2016-04-03 add levels of verboseness to stdout  
 2016-04-02 standardize verbose output to stdout in function  
 2016-03-30 add args for source and destination directories  
 2016-03-29 allow directories to be preserved in source via conf file  
 2016-03-27 rewrite to use rsync to only list changes (fixes overwrites)  


**backlog in no particular order:**  

- create a help function triggered by checking and --help or -? 
- implement check on success of rsync when creating the checksum_match
- add some checking for minimum versions of bash, rsync, etc.; once discovered, this should also be added to the documentation as well
- implement an internal log of files or directory changes and narrow the use of chown to only those
- consider the use of `trap` to ensure consistent state when forced to exit
- for efficiency, the structure changes loop should ignore owner and group differences because we very well might be enforcing the variance; this manifest itself when directories are not in the scaffolding to keep but have yet to be marked as stale
- consider use of echo -n or <<< to suppress newlines or eliminate piped sed
- verify quoted vars in all if statements
- verify proper use of [[ ]] in if statements
- test and check notices from http://www.shellcheck.net/
- implement check on success of rsync in hash check
- add different deconflicting options, like keeping file extension in tact
- add levels of verboseness to logging
- add exit codes 0, 1, etc.
- test links following behavior
- improve make\_filename\_unique to handle extensions (e.g. .txt)
- test moving of links, esp in light of: --include='\*/' --exclude='\*'
- test chown ownership of links see: --no-dereference flag in man page
- consider grouping piped sed and grep to one: sed -e 'pattern 1' -e 'pattern 2'
- implement use of warning_count and output even if not verbose or on sterr
- create option to inherit default ownership of receiving dir
- create option to inherit default permissions of receiving dir
- create a default ownership/permission behavior to change the files/directories that were changed
- if mv --no-clobber fails, see if it can be determined if collision, add to collision list
- check the difference in rsync --perms --owner --group and --acls
- add a feature to let files inherit the ownership from parent directory via: chown -R `stat . -c %u:%g` *
- at present files are filtered for ^>f.s|>f..t therefore attribute changes would be ignored, change to accommodate other changes
- add a --dry-run feature
- verify that the rm --force is not able to delete open, partially written files.







