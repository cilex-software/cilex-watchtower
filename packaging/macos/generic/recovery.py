"""Standalone native-dialog recovery entry; no action before Restore consent."""
import first_launch
import finder_update


def main():
    try:
        target = finder_update.installed_target()
        if target is None:
            raise ValueError('No installed Watchtower copy was found.')
        with first_launch.launch_lock(target):
            if not finder_update.recover_interrupted(target):
                finder_update.dialog(finder_update.text(
                    'No interrupted update needs recovery.', 'Незавершённых обновлений для восстановления нет.'))
        return 0
    except Exception as error:
        finder_update.dialog(finder_update.text(
            'Watchtower recovery did not finish.\n\n', 'Не удалось завершить восстановление Watchtower.\n\n') + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
