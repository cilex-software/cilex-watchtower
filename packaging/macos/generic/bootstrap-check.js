// Stock macOS JavaScript for Automation, using Foundation only (no automation UI).
ObjC.import('Foundation');
function run(argv) {
    var preferred = ObjC.unwrap($.NSLocale.preferredLanguages.firstObject) || 'en';
    var language = argv[1] === 'auto' ? (preferred.toLowerCase().indexOf('ru') === 0 ? 'ru' : 'en') : argv[1];
    var message = language === 'ru'
        ? 'Среда развёртывания отсутствует. Полная проверка и установка не выполнялись. Получите версионный комплект bootstrap с Setup.app у уполномоченного распространителя либо установите указанный в манифесте Python и передайте --python. Ничего не изменено.'
        : 'Deployment runtime is missing. Deep assessment and installation did not run. Obtain the versioned bootstrap bundle containing Setup.app from an authorized distributor, or manually provision the manifest Python and pass --python. No changes were made.';
    return JSON.stringify({schema_version:1, helper_version:'1.0.0', mode:argv[0], language:language,
        dry_run:argv[2] === '1', exit_code:11, states:{installation:'NotStarted',runtime_health:'Unverified',
        gui_video:'Unverified',backend:'Unverified',security_admission:'Unverified',recovery:'Unverified',
        startup:'StartupUnverified',rollback:'NotNeeded',cleanup:'NotNeeded'},
        host:{os:ObjC.unwrap($.NSProcessInfo.processInfo.operatingSystemVersionString)},
        findings:[{id:'bootstrap.runtime_missing',severity:'blocking',overridable:false,message:message}]});
}
