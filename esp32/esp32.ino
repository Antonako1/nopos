#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

#define SERIAL_RX 16
#define SERIAL_TX 17

#define LCD_SDA 21
#define LCD_SCL 22

#define LCD_ADDRESS 0x27
#define LCD_COLS 20
#define LCD_ROWS 4

#define OLED_WIDTH 128
#define OLED_HEIGHT 64
#define OLED_RESET -1
#define OLED_ADDRESS 0x3C

#define BAUD_RATE 115200

// Potentiometer
#define POT_PIN 34

// Push Button
#define BUTTON_PIN 23

// LEDs
#define LED_RED_PIN 25
#define LED_YELLOW_PIN 26
#define LED_GREEN_PIN 27

// ============================================================================
// MESSAGE BUFFER
// ============================================================================

// Number of lines retained in the scrollback buffer.
#define MAX_BUFFER_LINES 500

// LCD line width.
#define LINE_LENGTH 20

LiquidCrystal_I2C lcd(
    LCD_ADDRESS,
    LCD_COLS,
    LCD_ROWS
);

Adafruit_SSD1306 oled(
    OLED_WIDTH,
    OLED_HEIGHT,
    &Wire,
    OLED_RESET
);

bool oledFound = false;

HardwareSerial RS232(2);

// Circular scrollback buffer.
char msgBuffer[MAX_BUFFER_LINES][LINE_LENGTH + 1];

// Number of valid lines currently in the buffer.
int totalLines = 0;

// Index of the oldest line in the circular buffer.
int oldestLine = 0;

// Current line being written.
int currentWriteCol = 0;

// Potentiometer/display state.
int lastDisplayTopLine = -1;
int lastRawADC = -1;

// Command parser.
char cmdBuf[16];
int cmdIdx = 0;
bool parsingCmd = false;

// Button debounce.
unsigned long lastButtonPress = 0;


// ============================================================================
// BUFFER HELPERS
// ============================================================================

void clearBuffer()
{
    for (int i = 0; i < MAX_BUFFER_LINES; i++)
    {
        memset(msgBuffer[i], ' ', LINE_LENGTH);
        msgBuffer[i][LINE_LENGTH] = '\0';
    }

    totalLines = 0;
    oldestLine = 0;
    currentWriteCol = 0;

    lastDisplayTopLine = -1;
    lastRawADC = -1;

    lcd.clear();
}


// Return the physical buffer index for a logical line number.
//
// logicalLine:
//     0 = oldest retained line
//     1 = next line
//     ...
//
// This is important once the circular buffer wraps.
int getBufferIndex(int logicalLine)
{
    if (totalLines == 0)
        return 0;

    return (oldestLine + logicalLine) % MAX_BUFFER_LINES;
}


// Add a completely new line to the buffer.
void addNewLine()
{
    int newIndex;

    if (totalLines < MAX_BUFFER_LINES)
    {
        // Buffer isn't full yet.
        newIndex = (oldestLine + totalLines) % MAX_BUFFER_LINES;

        totalLines++;
    }
    else
    {
        // Buffer is full.
        //
        // Reuse the oldest line and move the oldest pointer forward.
        newIndex = oldestLine;

        oldestLine++;
        if (oldestLine >= MAX_BUFFER_LINES)
            oldestLine = 0;
    }

    memset(msgBuffer[newIndex], ' ', LINE_LENGTH);
    msgBuffer[newIndex][LINE_LENGTH] = '\0';

    currentWriteCol = 0;
}


// Append one character to the current line.
void appendCharToBuffer(char c)
{
    if (totalLines == 0)
    {
        addNewLine();
    }

    // Automatically wrap long strings at 20 characters.
    if (currentWriteCol >= LINE_LENGTH)
    {
        addNewLine();
    }

    int lineIdx = getBufferIndex(totalLines - 1);

    msgBuffer[lineIdx][currentWriteCol] = c;
    currentWriteCol++;
}


// ============================================================================
// OLED
// ============================================================================

void updateOLEDDisplay(bool rxActive = false)
{
    if (!oledFound)
        return;

    oled.clearDisplay();

    oled.setTextSize(1);
    oled.setTextColor(SSD1306_WHITE);

    // Header
    oled.setCursor(0, 0);
    oled.print("NopOS Monitor");

    if (rxActive)
    {
        oled.setCursor(92, 0);
        oled.print("[RX]");
    }

    oled.drawFastHLine(
        0,
        10,
        128,
        SSD1306_WHITE
    );

    // Buffer statistics
    oled.setCursor(0, 14);
    oled.print("Buffer: ");
    oled.print(totalLines);
    oled.print("/");
    oled.print(MAX_BUFFER_LINES);

    // Scroll position
    oled.setCursor(0, 26);
    oled.print("Top Line: ");

    if (lastDisplayTopLine >= 0)
        oled.print(lastDisplayTopLine + 1);
    else
        oled.print(0);

    // LED states
    oled.setCursor(0, 38);

    bool rOn = digitalRead(LED_RED_PIN);
    bool yOn = digitalRead(LED_YELLOW_PIN);
    bool gOn = digitalRead(LED_GREEN_PIN);

    oled.print("LEDs: R:");
    oled.print(rOn ? "1" : "0");

    oled.print(" Y:");
    oled.print(yOn ? "1" : "0");

    oled.print(" G:");
    oled.print(gOn ? "1" : "0");

    // Scroll progress bar
    int maxTopLine = totalLines - LCD_ROWS;

    int pct = 0;

    if (maxTopLine > 0 && lastDisplayTopLine >= 0)
    {
        pct = (lastDisplayTopLine * 100) / maxTopLine;

        if (pct > 100)
            pct = 100;
    }

    oled.drawRect(
        0,
        52,
        128,
        10,
        SSD1306_WHITE
    );

    int fillWidth = map(
        pct,
        0,
        100,
        0,
        124
    );

    if (fillWidth > 0)
    {
        oled.fillRect(
            2,
            54,
            fillWidth,
            6,
            SSD1306_WHITE
        );
    }

    oled.display();
}


// ============================================================================
// COMMAND PROCESSING
// ============================================================================

void processCommand(const char* cmd)
{
    if (strcmp(cmd, "!R1") == 0 ||
        strcmp(cmd, "!RED:ON") == 0)
    {
        digitalWrite(LED_RED_PIN, HIGH);
        Serial.println("[ESP32] RED LED ON");
    }
    else if (strcmp(cmd, "!R0") == 0 ||
             strcmp(cmd, "!RED:OFF") == 0)
    {
        digitalWrite(LED_RED_PIN, LOW);
        Serial.println("[ESP32] RED LED OFF");
    }
    else if (strcmp(cmd, "!Y1") == 0 ||
             strcmp(cmd, "!YELLOW:ON") == 0)
    {
        digitalWrite(LED_YELLOW_PIN, HIGH);
        Serial.println("[ESP32] YELLOW LED ON");
    }
    else if (strcmp(cmd, "!Y0") == 0 ||
             strcmp(cmd, "!YELLOW:OFF") == 0)
    {
        digitalWrite(LED_YELLOW_PIN, LOW);
        Serial.println("[ESP32] YELLOW LED OFF");
    }
    else if (strcmp(cmd, "!G1") == 0 ||
             strcmp(cmd, "!GREEN:ON") == 0)
    {
        digitalWrite(LED_GREEN_PIN, HIGH);
        Serial.println("[ESP32] GREEN LED ON");
    }
    else if (strcmp(cmd, "!G0") == 0 ||
             strcmp(cmd, "!GREEN:OFF") == 0)
    {
        digitalWrite(LED_GREEN_PIN, LOW);
        Serial.println("[ESP32] GREEN LED OFF");
    }
    else if (strcmp(cmd, "!CLEAR") == 0)
    {
        clearBuffer();
        Serial.println("[ESP32] BUFFER & LCD CLEARED");
    }

    updateOLEDDisplay();
}


// ============================================================================
// POTENTIOMETER
// ============================================================================

int readPotentiometerSmooth(int pin)
{
    long sum = 0;

    for (int i = 0; i < 16; i++)
    {
        sum += analogRead(pin);
    }

    return (int)(sum / 16);
}


// ============================================================================
// TEST DATA
// ============================================================================

void populateTestBuffer()
{
    clearBuffer();

    const char* sampleLines[] =
    {
        "01: NopOS Boot OK",
        "02: Testing Scroll",
        "03: Turn Pot (G34)",
        "04: Line 04 Hello",
        "05: Line 05 World",
        "06: Line 06 ESP32",
        "07: Line 07 System",
        "08: Line 08 Buffer",
        "09: Line 09 Active",
        "10: Line 10 Serial",
        "11: Line 11 115200",
        "12: Line 12 Ready",
        "13: Line 13 LED:R25",
        "14: Line 14 LED:Y26",
        "15: Line 15 LED:G27",
        "16: Line 16 BTN:C23"
    };

    int count =
        sizeof(sampleLines) /
        sizeof(sampleLines[0]);

    for (int i = 0; i < count; i++)
    {
        addNewLine();

        int lineIdx =
            getBufferIndex(totalLines - 1);

        strncpy(
            msgBuffer[lineIdx],
            sampleLines[i],
            LINE_LENGTH
        );

        int len = strlen(sampleLines[i]);

        for (int j = len; j < LINE_LENGTH; j++)
        {
            msgBuffer[lineIdx][j] = ' ';
        }

        msgBuffer[lineIdx][LINE_LENGTH] = '\0';
    }
}


// ============================================================================
// LCD
// ============================================================================

void updateLCDDisplay(bool forceRedraw = false)
{
    if (totalLines == 0)
    {
        updateOLEDDisplay();
        return;
    }

    int maxTopLine = totalLines - LCD_ROWS;

    if (maxTopLine < 0)
        maxTopLine = 0;

    // Read potentiometer.
    int adcVal =
        readPotentiometerSmooth(POT_PIN);

    // Hysteresis / deadband.
    if (!forceRedraw &&
        lastRawADC >= 0 &&
        abs(adcVal - lastRawADC) < 45 &&
        lastDisplayTopLine != -1)
    {
        adcVal = lastRawADC;
    }
    else
    {
        lastRawADC = adcVal;
    }

    // Convert potentiometer position to scroll position.
    int topLine =
        map(
            adcVal,
            0,
            4095,
            0,
            maxTopLine
        );

    topLine =
        constrain(
            topLine,
            0,
            maxTopLine
        );

    // Redraw only when necessary.
    if (topLine != lastDisplayTopLine ||
        forceRedraw)
    {
        lastDisplayTopLine = topLine;

        for (int r = 0; r < LCD_ROWS; r++)
        {
            int logicalLine =
                topLine + r;

            lcd.setCursor(0, r);

            if (logicalLine < totalLines)
            {
                int bufferIndex =
                    getBufferIndex(logicalLine);

                char lineText[LINE_LENGTH + 1];

                memcpy(
                    lineText,
                    msgBuffer[bufferIndex],
                    LINE_LENGTH
                );

                lineText[LINE_LENGTH] = '\0';

                lcd.print(lineText);
            }
            else
            {
                lcd.print("                    ");
            }
        }
    }

    updateOLEDDisplay();
}


// ============================================================================
// BUTTON
// ============================================================================

void checkButton()
{
    if (digitalRead(BUTTON_PIN) == LOW)
    {
        unsigned long now = millis();

        if (now - lastButtonPress > 250)
        {
            lastButtonPress = now;

            clearBuffer();

            updateOLEDDisplay();

            Serial.println(
                "[ESP32] Button Pressed -> "
                "LCD & Buffer Cleared!"
            );
        }
    }
}


// ============================================================================
// SETUP
// ============================================================================

void setup()
{
    // USB serial debug
    Serial.begin(115200);

    // Pins
    pinMode(POT_PIN, INPUT);
    pinMode(BUTTON_PIN, INPUT_PULLUP);

    pinMode(LED_RED_PIN, OUTPUT);
    pinMode(LED_YELLOW_PIN, OUTPUT);
    pinMode(LED_GREEN_PIN, OUTPUT);

    digitalWrite(LED_RED_PIN, LOW);
    digitalWrite(LED_YELLOW_PIN, LOW);
    digitalWrite(LED_GREEN_PIN, LOW);

    // Buffer
    clearBuffer();

    // I2C
    Wire.begin(
        LCD_SDA,
        LCD_SCL
    );

    // LCD
    lcd.init();
    lcd.backlight();
    lcd.clear();

    lcd.setCursor(0, 0);
    lcd.print("NopOS Serial RX");

    lcd.setCursor(0, 1);
    lcd.print("115200 8N1 (20x4)");

    // OLED
    if (oled.begin(
        SSD1306_SWITCHCAPVCC,
        OLED_ADDRESS))
    {
        oledFound = true;

        oled.clearDisplay();
        oled.setTextSize(1);
        oled.setTextColor(SSD1306_WHITE);

        oled.setCursor(0, 10);
        oled.println("NopOS System Dash");
        oled.println("OLED 0x3C Ready!");

        oled.display();
    }
    else
    {
        Serial.println(
            "[ESP32] Warning: "
            "SSD1306 OLED not found at 0x3C"
        );
    }

    // MAX3232 UART
    RS232.begin(
        BAUD_RATE,
        SERIAL_8N1,
        SERIAL_RX,
        SERIAL_TX
    );

    Serial.println(
        "NopOS serial receiver started"
    );

    Serial.println(
        "115200 8N1 "
        "(Scroll: POT34, "
        "Clear: BTN23, "
        "LEDs: R25, Y26, G27)"
    );

    delay(1000);

    lcd.clear();

    // Test data
    populateTestBuffer();

    updateLCDDisplay(true);
}


// ============================================================================
// MAIN LOOP
// ============================================================================

void loop()
{
    bool receivedNewData = false;

    checkButton();

    while (RS232.available())
    {
        char c = RS232.read();

        // Echo raw character to USB serial.
        Serial.write(c);


        // ====================================================================
        // COMMAND PARSER
        // ====================================================================

        if (c == '!')
        {
            parsingCmd = true;
            cmdIdx = 0;

            cmdBuf[cmdIdx++] = c;

            continue;
        }

        if (parsingCmd)
        {
            // Command terminators.
            //
            // A NUL terminates the command exactly like CR/LF,
            // and ALSO starts a new scroll-buffer row.
            if (c == '\r' ||
                c == '\n' ||
                c == ' ' ||
                c == '\0' ||
                cmdIdx >= 14)
            {
                cmdBuf[cmdIdx] = '\0';

                processCommand(cmdBuf);

                parsingCmd = false;
                cmdIdx = 0;

                // NUL means the complete string ended here.
                // Keep the next string on its own row.
                if (c == '\0')
                {
                    addNewLine();
                    receivedNewData = true;
                }

                continue;
            }

            cmdBuf[cmdIdx++] = c;

            continue;
        }


        // ====================================================================
        // FORM FEED
        // ====================================================================

        if (c == '\f')
        {
            clearBuffer();

            receivedNewData = true;

            continue;
        }


        // ====================================================================
        // CARRIAGE RETURN
        // ====================================================================

        if (c == '\r')
        {
            continue;
        }


        // ====================================================================
        // NEWLINE
        // ====================================================================

        if (c == '\n')
        {
            addNewLine();

            receivedNewData = true;

            continue;
        }


        // ====================================================================
        // NUL STRING TERMINATOR
        // ====================================================================
        //
        // This is the important change.
        //
        // Input:
        //
        //     "HELLO\0WORLD\0TEST\0"
        //
        // becomes:
        //
        //     HELLO
        //     WORLD
        //     TEST
        //
        // Each NUL terminates the current string and creates
        // the next scroll-buffer row.

        if (c == '\0')
        {
            addNewLine();

            receivedNewData = true;

            continue;
        }


        // ====================================================================
        // NORMAL CHARACTER
        // ====================================================================

        appendCharToBuffer(c);

        receivedNewData = true;
    }


    // Update LCD/OLED.
    updateLCDDisplay(receivedNewData);

    delay(10);
}