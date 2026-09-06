// Small macOS PTY bridge. stdin: opcode + little-endian uint32 size + payload.
// Input opcode 0; resize opcode 1 with little-endian uint16 columns, rows.
#include <util.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static volatile sig_atomic_t stopped = 0;
static void stop(int sig) { (void)sig; stopped = 1; }
static uint32_t le32(const unsigned char *p) { return p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static int write_all(int fd, const void *data, size_t size) {
    const char *p=data;
    while(size) { ssize_t n=write(fd,p,size); if(n<0&&errno==EINTR&&!stopped)continue; if(n<=0)return -1; p+=n;size-=n; }
    return 0;
}
int main(int argc,char **argv) {
    if(argc!=3) {fprintf(stderr,"Terminal requires a folder and shell\n");return 2;}
    struct winsize size={.ws_row=24,.ws_col=80};int master;
    pid_t child=forkpty(&master,NULL,NULL,&size);
    if(child<0){perror("forkpty");return 1;}
    if(child==0){
        if(chdir(argv[1])<0){perror("workspace");_exit(1);}
        setenv("TERM","xterm-256color",1);setenv("COLORTERM","truecolor",1);
        execl(argv[2],argv[2],"-l",(char*)NULL);perror("shell");_exit(1);
    }
    struct sigaction action={0}; action.sa_handler=stop; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM,&action,NULL);sigaction(SIGINT,&action,NULL);sigaction(SIGHUP,&action,NULL);signal(SIGPIPE,SIG_IGN);
    unsigned char input[131077],output[16384];size_t used=0;int status=0;
    while(!stopped){
        struct pollfd fds[2]={{.fd=STDIN_FILENO,.events=POLLIN},{.fd=master,.events=POLLIN}};
        if(poll(fds,2,250)<0){if(errno==EINTR)continue;break;}
        if(fds[1].revents&(POLLIN|POLLHUP)){
            ssize_t n=read(master,output,sizeof(output));
            if(n<=0)break;
            if(write_all(STDOUT_FILENO,output,(size_t)n)<0)break;
        }
        if(fds[0].revents&POLLIN){
            ssize_t n=read(STDIN_FILENO,input+used,sizeof(input)-used);if(n<=0)break;used+=(size_t)n;
            while(used>=5){
                uint32_t length=le32(input+1);if(length>131072){stopped=1;break;}
                if(used<5+length)break;
                if(input[0]==0){if(write_all(master,input+5,length)<0){stopped=1;break;}}
                else if(input[0]==1&&length==4){
                    unsigned cols=input[5]|input[6]<<8, rows=input[7]|input[8]<<8;
                    if(cols>=2&&cols<=1000&&rows>=1&&rows<=500){size.ws_col=cols;size.ws_row=rows;ioctl(master,TIOCSWINSZ,&size);}
                }else{stopped=1;break;}
                used-=5+length;memmove(input,input+5+length,used);
            }
        }
        if(fds[0].revents&(POLLHUP|POLLERR|POLLNVAL))break;
    }
    close(master);
    if(child>0){
        kill(-child,SIGHUP);
        for(int i=0;i<20;i++){if(waitpid(child,&status,WNOHANG)==child){child=0;break;}usleep(10000);}
        if(child>0){kill(-child,SIGKILL);waitpid(child,&status,0);}
    }
    return WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);
}
