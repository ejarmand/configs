multikill() {
	ps -aux | grep $1 | sed 's/  */\t/g' | cut -f 2 | while read -r pid; do kill $pid; done
}

alias gitls='git ls-tree -r --name-only -z HEAD | xargs -0 -n1 -I{} -- git log -1 --format="%ai %an {}" -- "{}"'
