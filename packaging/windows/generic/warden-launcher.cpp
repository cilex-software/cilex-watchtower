// Deployment helper, not part of the selected Watchtower/Warden source revision.
// Keep one scheduled action's Warden and all descendants in an owned lifetime.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#define WTG_LAUNCHER_VERSION "1.0.0"
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

namespace {
class Handle {
public:
    explicit Handle(HANDLE value=nullptr) noexcept : value_(value) {}
    ~Handle() { if(value_ && value_!=INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle&)=delete;
    Handle& operator=(const Handle&)=delete;
    HANDLE get() const noexcept { return value_; }
    explicit operator bool() const noexcept { return value_ && value_!=INVALID_HANDLE_VALUE; }
private:
    HANDLE value_;
};

class Attributes {
public:
    ~Attributes() {
        if(initialized_) DeleteProcThreadAttributeList(list_);
        if(list_) HeapFree(GetProcessHeap(),0,list_);
    }
    bool initialize(HANDLE* job) {
        SIZE_T bytes=0;
        InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
        if(!bytes) return false;
        list_=static_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(HeapAlloc(GetProcessHeap(),0,bytes));
        if(!list_) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return false; }
        if(!InitializeProcThreadAttributeList(list_,1,0,&bytes)) return false;
        initialized_=true;
        // Assignment is atomic with process creation. The launcher dying between
        // CreateProcess and a separate AssignProcess call must not leave an orphan.
        return UpdateProcThreadAttribute(list_,0,PROC_THREAD_ATTRIBUTE_JOB_LIST,
            job,sizeof(*job),nullptr,nullptr)!=FALSE;
    }
    LPPROC_THREAD_ATTRIBUTE_LIST get() const noexcept { return list_; }
private:
    LPPROC_THREAD_ATTRIBUTE_LIST list_=nullptr;
    bool initialized_=false;
};

DWORD failure() noexcept { const DWORD value=GetLastError(); return value ? value : ERROR_GEN_FAILURE; }

std::wstring modulePath() {
    for(DWORD size=512;size<=32768;size*=2) {
        std::vector<wchar_t> path(size);
        const DWORD length=GetModuleFileNameW(nullptr,path.data(),size);
        if(!length) return {};
        if(length<size) return std::wstring(path.data(),length);
    }
    SetLastError(ERROR_FILENAME_EXCED_RANGE);return {};
}

DWORD launch() {
    int count=0;
    wchar_t** arguments=CommandLineToArgvW(GetCommandLineW(),&count);
    if(!arguments) return failure();
    const bool valid=(count==2 && wcscmp(arguments[1],L"run")==0);
    LocalFree(arguments);
    if(!valid) return ERROR_INVALID_PARAMETER;
    const std::wstring module=modulePath();
    if(module.empty()) return failure();
    const auto slash=module.find_last_of(L"\\/");
    if(slash==std::wstring::npos) return ERROR_BAD_PATHNAME;
    const std::wstring directory=module.substr(0,slash);
    const auto parentSlash=directory.find_last_of(L"\\/");
    if(parentSlash==std::wstring::npos || parentSlash<3) return ERROR_BAD_PATHNAME;
    const std::wstring workingDirectory=directory.substr(0,parentSlash);
    const std::wstring executable=directory+L"\\warden.exe";
    std::wstring command=L"\""+executable+L"\" run";

    // Unnamed, noninheritable; no breakaway flags. The kernel closes this handle
    // even if the launcher is forcibly terminated and ends only this job's tree.
    Handle job(CreateJobObjectW(nullptr,nullptr));
    if(!job) return failure();
    if(!SetHandleInformation(job.get(),HANDLE_FLAG_INHERIT,0)) return failure();
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if(!SetInformationJobObject(job.get(),JobObjectExtendedLimitInformation,&limits,sizeof(limits))) return failure();
    HANDLE jobValue=job.get();
    Attributes attributes;
    if(!attributes.initialize(&jobValue)) return failure();
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb=sizeof(startup);
    startup.lpAttributeList=attributes.get();
    PROCESS_INFORMATION created{};
    if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,
        CREATE_SUSPENDED|CREATE_NO_WINDOW|EXTENDED_STARTUPINFO_PRESENT,
        nullptr,workingDirectory.c_str(),&startup.StartupInfo,&created)) return failure();
    Handle process(created.hProcess),thread(created.hThread);
    BOOL assigned=FALSE;
    if(!IsProcessInJob(process.get(),job.get(),&assigned) || !assigned) {
        const DWORD error=failure();
        // Retained created handle only; never search names or terminate an
        // unrelated process. The thread has not been allowed to execute.
        TerminateProcess(process.get(),error);WaitForSingleObject(process.get(),5000);
        return error;
    }
    if(ResumeThread(thread.get())!=1) {
        const DWORD error=failure();
        TerminateProcess(process.get(),error);WaitForSingleObject(process.get(),5000);
        return error;
    }
    if(WaitForSingleObject(process.get(),INFINITE)!=WAIT_OBJECT_0) return failure();
    DWORD result=ERROR_GEN_FAILURE;
    if(!GetExitCodeProcess(process.get(),&result)) return failure();
    // job's destruction removes lingering descendants on every return path.
    return result;
}
}

int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    return static_cast<int>(launch());
}
