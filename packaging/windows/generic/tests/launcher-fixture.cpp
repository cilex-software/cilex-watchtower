// Harmless, bounded stand-in for a supervisor and child. Never starts Watchtower.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

static std::wstring environment(const wchar_t* name) {
    const DWORD count=GetEnvironmentVariableW(name,nullptr,0);
    if(!count || count>32768) return {};
    std::vector<wchar_t> value(count);
    if(!GetEnvironmentVariableW(name,value.data(),count)) return {};
    return value.data();
}
static bool record(const std::wstring& root,const wchar_t* role) {
    FILETIME created,exited,kernel,user;
    if(!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user)) return false;
    ULARGE_INTEGER stamp;stamp.LowPart=created.dwLowDateTime;stamp.HighPart=created.dwHighDateTime;
    DWORD session=0;ProcessIdToSessionId(GetCurrentProcessId(),&session);
    std::vector<wchar_t> cwd(32768);
    if(!GetCurrentDirectoryW(static_cast<DWORD>(cwd.size()),cwd.data())) return false;
    const std::wstring content=L"\ufeffpid="+std::to_wstring(GetCurrentProcessId())+
        L"\ncreated="+std::to_wstring(stamp.QuadPart)+L"\nsession="+std::to_wstring(session)+L"\ncwd="+cwd.data()+L"\n";
    const std::wstring path=root+L"\\"+role+L".txt";
    HANDLE file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(file==INVALID_HANDLE_VALUE) return false;
    const DWORD bytes=static_cast<DWORD>(content.size()*sizeof(wchar_t));DWORD written=0;
    const BOOL good=WriteFile(file,content.data(),bytes,&written,nullptr);CloseHandle(file);
    return good && written==bytes;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    const std::wstring root=environment(L"WTG_LAUNCHER_FIXTURE_ROOT");
    const std::wstring mode=environment(L"WTG_LAUNCHER_FIXTURE_MODE");
    if(root.size()<3 || root[1]!=L':' || root[2]!=L'\\' || mode.empty()) return 20;
    int count=0;wchar_t** args=CommandLineToArgvW(GetCommandLineW(),&count);
    if(!args || count!=2) return 21;
    const std::wstring role=args[1];LocalFree(args);
    if(role==L"leaf") {
        if(!record(root,L"leaf")) return 22;
        Sleep(90000);return 0;
    }
    if(role!=L"run") return 23;
    std::vector<wchar_t> module(32768);
    const DWORD length=GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    if(!length || length>=module.size()) return 24;
    const std::wstring own(module.data(),length);
    const auto slash=own.find_last_of(L"\\");if(slash==std::wstring::npos) return 25;
    const std::wstring child=own.substr(0,slash)+L"\\fixture-leaf.exe";
    std::wstring command=L"\""+child+L"\" leaf";
    STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
    if(!CreateProcessW(child.c_str(),command.data(),nullptr,nullptr,FALSE,
        CREATE_NEW_PROCESS_GROUP|CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process)) return 26;
    CloseHandle(process.hThread);CloseHandle(process.hProcess);
    if(!record(root,L"warden")) return 27;
    if(mode==L"normal-exit" || mode==L"zero-exit") {
        // The test first retains both process identities. A fixed short sleep
        // races a loaded build host and never proves a live child was observed.
        const std::wstring ready=root+L"\\continue.txt";
        const ULONGLONG deadline=GetTickCount64()+90000;
        while(GetFileAttributesW(ready.c_str())==INVALID_FILE_ATTRIBUTES) {
            if(GetTickCount64()>=deadline) return 28;
            Sleep(50);
        }
        return mode==L"normal-exit" ? 37 : 0;
    }
    Sleep(90000);return 0;
}
