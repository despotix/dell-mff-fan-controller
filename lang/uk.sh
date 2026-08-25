# Ukrainian messages. Loaded when FANCTL_LANG=uk.
#
# Anything not defined here keeps its English value, so a partial translation is
# safe. Keep every %s conversion, in the same order as the English string.

# ---- install.sh ----
MI_NEED_ROOT="Запускай через sudo: sudo ./install.sh"
MI_PANIC_TRIPPED="!! Захист від перегріву заклинено — керування вентилятором ВИМКНЕНО, поки це не прибрати:"
MI_PANIC_TRACE="   Латч: %s (прибери вручну, коли розберешся з причиною)\n"
MI_ENTER_INT="  Введіть ціле число від %s до %s.\n"
MI_ANSWER_YN="  Відповідь: y або n."
MI_PROBE_NO_DELL="   dell_smm hwmon не знайдено — пропускаю зонд."
MI_PROBE_NO_WRITE="   %s не записуваний — пропускаю зонд.\n"
MI_PROBE_STOPPING="   зупиняю optiplex-fan на час зонда..."
MI_PROBE_BIOS="   міряю BIOS auto на холостому ходу..."
MI_PROBE_NO_MANUAL="   ручний режим недоступний."
MI_PROBE_BOOST="   міряю boost (255 записати один раз)..."
MI_PROBE_PURGE="   міряю purge (255 переписувати щодві секунди)..."
MI_HEADER="== Налаштування керування вентилятором =="
MI_FOUND_CONF="Знайдено наявний конфіг %s — поточні значення показані в дужках.\n"
MI_KEEP_HINT="Enter — лишити значення в дужках без змін."
MI_ZONES="Плавної кривої тут не буде — EC має дискретні рівні. Демон вибирає
один із чотирьох станів під поточну температуру:
  нижче T_QUIET-T_HYST : quiet     рівень 1
  T_QUIET .. T_BOOST   : BIOS auto штатна крива
  T_BOOST .. T_PURGE   : boost     верхній рівень, записаний один раз
  від T_PURGE          : purge     той самий рівень, але з перезаписом"
MI_ZONES_WHY="boost і purge — це один рівень EC. Різниця в тому, що кожен запис у
pwm1 викликає короткий продув, тож постійний перезапис тримає оберти,
яких рівень сам по собі не дає."
MI_PROBE_HEADER="== Зонд заліза (~50с) =="
MI_PROBE_WHY="Міряю, які оберти дає кожен стан саме на ЦІЙ машині — щоб дефолти були
з твого заліза, а не з чужого OptiPlex. Буде гучно."
MI_PROBE_ASK="Прогнати зонд?"
MI_PROBE_FAILED="   зонд не вдався, беру вбудовані значення"
MI_PROBE_RESULTS="   Заміряно на цій машині:"
MI_PROBE_QUIET="     тихий рівень   %s об/хв\n"
MI_PROBE_IDLE="     BIOS на idle   %s об/хв\n"
MI_PROBE_BOOST_RPM="     boost          %s об/хв\n"
MI_PROBE_PURGE_RPM="     purge          %s об/хв\n"
MI_PROBE_BOUNDARY="     верхній рівень починається з pwm %s\n"
MI_WARN_QUIET="   !! Тихий рівень не тихіший за BIOS auto — нижня зона тут нічого не
      дає. Постав T_QUIET низько, щоб її обійти."
MI_WARN_PURGE="   !! Перезапис не дає приросту — на цій машині purge == boost.
      Можеш вимкнути верхню зону (T_PURGE=0)."
MI_Q_TQUIET="T_QUIET — температура (°C), з якої керування віддається BIOS"
MI_Q_THYST="T_HYST — на скільки °C нижче T_QUIET повертатись у тихий режим"
MI_Q_TBOOST="T_BOOST — температура (°C) для boost"
MI_Q_TPURGE="T_PURGE — температура (°C) для purge"
MI_Q_OFF="0 = вимкнути"
MI_Q_THOTHYST="T_HOT_HYST — на скільки °C нижче порога відпускати верхні зони"
MI_Q_QUIETPWM="QUIET_PWM — рівень у тихому режимі"
MI_Q_INTERVAL="INTERVAL — як часто перевіряти температуру, сек"
MI_PANIC_HEADER="== Захист від перегріву (необов'язковий) =="
MI_PANIC_WHAT="Якщо CPU досягає T_PANIC — фан уже на максимумі й не витягує — демон
вмикає сигналізацію і жене продув. Далі в нього є PANIC_TIMEOUT секунд,
щоб збити пакет назад до PANIC_RECOVER:
  збив         сигналу вистачило, робота триває як звичайно
  не збив      один довгий біп, і машина вимикається
Машина, вимкнена таким чином, повертається з ВИМКНЕНИМ керуванням
вентилятором: сервіс стартує і пікає, що заклинений, — але за температурою
продовжує стежити: перевищення LATCH_T_PANIC означає продув і вимкнення, —
поки не прибрати /var/lib/optiplex-fan/panic."
MI_PANIC_AGAINST="Проти: --force пропускає штатний розмонтаж, а поріг мусить бути вище за
те, що дають реальні навантаження — тут заміряно 91°C під повним
навантаженням при тротлінгу CPU на 100°C. Замалий поріг означає
вимкнення сервера посеред звичайної збірки."
MI_PANIC_ASK="Увімкнути захист від перегріву?"
MI_Q_TPANIC="T_PANIC — температура (°C), яка вмикає сигнал і продув"
MI_Q_PRECOVER="PANIC_RECOVER — до якої температури (°C) треба збити назад"
MI_Q_PTIMEOUT="PANIC_TIMEOUT — скільки секунд на це дається"
MI_PANIC_ACTION_WHY="   Вимкнення безпечніше за ребут: пакет, який не вдалося остудити на ходу,
   не остудиться від того, що машина одразу підніметься назад у те саме
   навантаження, а під час POST вентилятором взагалі ніхто не керує."
MI_Q_PACTION="PANIC_ACTION — що робити, якщо не збило [poweroff/reboot] (%s): "
MI_SUM_HEAD="Підсумок: тихо нижче %s°C, BIOS auto від %s°C, перевірка кожні %sс\n"
MI_SUM_BOOST="          boost від %s°C (відпускає нижче %s°C)\n"
MI_SUM_BOOST_OFF="          boost вимкнено"
MI_SUM_PURGE="          purge від %s°C (відпускає нижче %s°C)\n"
MI_SUM_PURGE_OFF="          purge вимкнено"
MI_SUM_PANIC="          захист від перегріву: сигнал + продув на %s°C,
          %s, якщо не збито до %s°C за %sс\n"
MI_SUM_PANIC_OFF="          захист від перегріву вимкнено"
MI_CONFIRM="Записати це в %s і продовжити встановлення? [Y/n]: "
MI_CANCELLED="Скасовано, нічого не змінено."
MI_NONINTERACTIVE="Неінтерактивний режим: використовую %s.\n"
MI_NI_EXISTING="наявний %s"
MI_NI_DEFAULTS="вбудовані значення"
MI_LOADING_MODULE="Завантажую модуль dell_smm_hwmon..."
MI_DONE="Встановлено й запущено з конфігом %s.\n"
MI_HINT_STATUS="Стан:     systemctl status optiplex-fan"
MI_HINT_LOG="Живий лог: journalctl -u optiplex-fan -f"
MI_HINT_RECONF="Змінити:  sudo ./install.sh   (ті самі питання, поточні значення як дефолт)"
MI_ALARM_HEADER="== Звукова сигналізація (необов'язково) =="
MI_ALARM_WHAT="Усі аварійні шляхи тут закінчуються поверненням до BIOS auto — тихо й
мовчки. Сигналізація — це те, що таки скаже, внутрішнім спікером:
  два коротких піки  проблема зараз: демон не працює, або спрацював
                     захист від перегріву і йде продув
  три довгих піки    керування вентилятором ВИМКНЕНО: захист заклинило,
                     машина на стоковій кривій, поки це не прибрати
Демон пікає сам за себе, а окремий маленький сервіс через %sс після
старту дивиться, чи взагалі працює optiplex-fan — це єдиний випадок,
про який мертвий демон сказати не може. Тоді виходить; далі не нудить."
MI_ALARM_ASK="Поставити звукову сигналізацію?"
MI_ALARM_NO_SOUND="   Увага: тут не знайдено ні PC speaker (pcspkr), ні звукової карти.
   Ставлю все одно — у лог воно пише в будь-якому разі, а спікер може
   з'явитись після ребуту. Дивись ALARM_BACKEND у конфізі."
MI_ALARM_TEST_ASK="Пікнути зараз, щоб перевірити спікер?"
MI_ALARM_HEARD="Чути було?"
MI_ALARM_TRYING="   Пробую бекенд %s...\n"
MI_ALARM_TRYING_DEV="   Пробую звукову карту через %s...\n"
MI_ALARM_NEXT="   Значить, до баззера нічого не підпаяно. Іду по виходах звукової
   карти по черзі — скажеш, коли почуєш."
MI_ALARM_PINNED="   Лишаю %s.\n"
MI_ALARM_DEAF="   Значить, ця машина не видає звуку взагалі. Перевір, чи ввімкнені
   колонки й чи піднятий мікшер, або пропиши ALARM_BACKEND / ALARM_ALSA_DEV
   у %s вручну. У журнал воно пише в будь-якому разі.\n"
MI_Q_ALARM_DELAY="ALARM_DELAY — через скільки секунд після старту перевіряти"
MI_Q_ALARM_REPEATS="ALARM_REPEATS — скільки разів повторити піки"
MI_SUM_ALARM="          пікання через %sс після старту, повторів: %s\n"
MI_SUM_ALARM_OFF="          пікання на старті вимкнено"
MI_HINT_REMOVE="Прибрати: sudo ./uninstall.sh"
MI_HINT_ALARM="Тест піку: sudo optiplex-fan-alarm.sh --test"

# ---- uninstall.sh ----
MU_NEED_ROOT="Запускай через sudo: sudo ./uninstall.sh"
MU_REMOVED="Сервіс прибрано. Автоматичне керування BIOS повернулось при його зупинці."
MU_ALARM_REMOVED="Пікалку на старті теж прибрано — на наступному ребуті ніщо не пікне."
MU_CONF_KEPT="Конфіг /etc/optiplex-fan.conf лишено — прибери вручну, якщо треба: sudo rm /etc/optiplex-fan.conf"
MU_PANIC_KEPT="Латч захисту від перегріву лишено: /var/lib/optiplex-fan/panic"

# ---- fan-diag.sh ----
MD_NEED_ROOT="Запускай через sudo: sudo ./fan-diag.sh"
MD_NO_DELL="dell_smm hwmon не знайдено — dell_smm_hwmon завантажений?"
MD_NO_CORETEMP="coretemp hwmon не знайдено"
MD_NO_PKG="сенсор 'Package id 0' не знайдено"
MD_RESTORED="== відновлено pwm1_enable=2 (BIOS auto) =="
MD_TEMP_SRC="Джерело температури: %s\n"
MD_PWM_CTL="Керування: %s (enable: %s)\n"
MD_BIOS_TOKEN="== BIOS-токен =="
MD_NO_CCTK="cctk не встановлено"
MD_STEP1="== 1) як зараз (pwm1_enable=%s) ==\n"
MD_STEP2="== 2) pwm1_enable=1 (ручний режим, керування EC вимкнено) =="
MD_STEP3="== 3) pwm1=%s ==\n"
MD_STEP4="== 4) назад у pwm1_enable=2 =="

# ---- pwm-sweep.sh ----
MS_NEED_ROOT="Запускай через sudo: sudo ./pwm-sweep.sh"
MS_NO_DELL="dell_smm не знайдено"
MS_RESTORING="== відновлення =="
MS_STARTED="   optiplex-fan запущено назад"
MS_WAS_STOPPED="   сервіс і був зупинений, лишаю як є"
MS_STOPPING="Зупиняю optiplex-fan на час тесту..."
MS_MANUAL="Ручний режим, пауза %sс на кожне значення.\n"
MS_HDR_WRITTEN="записав"
MS_HDR_READBACK="readback"
MS_HDR_RPM="об/хв"
MS_HDR_TEMP="темп"
MS_HDR_LEVEL="рівень EC"
MS_REFUSED="ВІДМОВА"
MS_JUMP="  <-- СТРИБОК"
MS_OUT_OF_RANGE="== спроби вийти за діапазон =="
MS_ACCEPTED="  запис %-6s -> ПРИЙНЯТО (rc=0), readback=%s, об/хв=%s\n"
MS_REJECTED="  запис %-6s -> відхилено: %s\n"
MS_ENABLE_HDR="== pwm1_enable: чи є режими крім 1 і 2 =="
MS_EN_ACCEPTED="  enable=%-2s -> ПРИЙНЯТО, readback=%s, об/хв=%s\n"
MS_EN_REJECTED="  enable=%-2s -> відхилено: %s\n"
MS_REFERENCE="== довідково =="
MS_FAN_MAX="  атрибут fan1_max: %s\n"
MS_FAN_MIN="  атрибут fan1_min: %s\n"

# ---- thermal-test.sh ----
MT_NO_DELL="dell_smm hwmon не знайдено"
MT_NO_CORETEMP="coretemp hwmon не знайдено"
MT_NO_PKG="сенсор 'Package id 0' не знайдено"
MT_LOAD_STRESS="Навантаження: stress-ng --cpu %s --cpu-method matrixprod\n"
MT_LOAD_OPENSSL="Навантаження: openssl aes-256-gcm x %s (stress-ng не встановлений)\n"
MT_NO_LOADER="Немає ні stress-ng, ні openssl — нічим вантажити."
MT_PLAN="%sс навантаження, потім %sс остигання. Знімаю навантаження на %s°C.\n"
MT_HDR_SEC="сек"
MT_HDR_TEMP="темп"
MT_HDR_PEAK="макс"
MT_HDR_RPM="об/хв"
MT_HDR_ZONE="зона"
MT_LOAD_DONE="--- навантаження знято ---"
MT_ABORTED="--- досягнуто %s°C: навантаження знято достроково ---\n"
MT_SUMMARY="== ПІДСУМОК =="
MT_PEAK="Максимум пакета:       %s°C\n"
MT_FIRST_MAX="Перший MAX на:         %s\n"
MT_NEVER="не вмикався"
MT_TOTAL_MAX="Сумарно в зоні MAX:    %sс\n"
MT_TOGGLES="Перемикань між зонами: %s\n"
MT_NOTE_ABORT="УВАГА: зупинено достроково на %s°C — справжня стеля вища за %s°C.\n"
