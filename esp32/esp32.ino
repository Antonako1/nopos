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

// Potentiometer Pin (ADC1_CH6 - Input Only Pin)
#define POT_PIN 34

// Push Button Pin (4-pin tactile switch with internal pullup)
#define BUTTON_PIN 23

// LED Pins
#define LED_RED_PIN 25
#define LED_YELLOW_PIN 26
#define LED_GREEN_PIN 27

// Message Buffer Configuration
#define MAX_BUFFER_LINES 50
#define LINE_LENGTH 20

LiquidCrystal_I2C lcd(
    LCD_ADDRESS,
    LCD_COLS,
    LCD_ROWS
);

Adafruit_SSD1306 oled(OLED_WIDTH, OLED_HEIGHT, &Wire, OLED_RESET);
bool oledFound = false;

HardwareSerial RS232(2);

// Circular Buffer for storing lines
char msgBuffer[MAX_BUFFER_LINES][LINE_LENGTH + 1];
int totalLines = 0;       // Total lines stored so far
int currentWriteCol = 0; // Current column in line being built

// Potentiometer state & rendering tracking
int lastDisplayTopLine = -1;
int lastRawADC = -1;

// Command parser buffer for LED commands (e.g. !R1, !Y1, !G1, !R0, !Y0, !G0)
char cmdBuf[16];
int cmdIdx = 0;
bool parsingCmd = false;

// Button debounce
unsigned long lastButtonPress = 0;

void clearBuffer() {
    for (int i = 0; i < MAX_BUFFER_LINES; i++) {
        memset(msgBuffer[i], ' ', LINE_LENGTH);
        msgBuffer[i][LINE_LENGTH] = '\0';
    }
    totalLines = 0;
    currentWriteCol = 0;
    lastDisplayTopLine = -1;
    lcd.clear();
}

void addNewLine() {
    totalLines++;
    currentWriteCol = 0;
    int lineIdx = (totalLines - 1) % MAX_BUFFER_LINES;
    memset(msgBuffer[lineIdx], ' ', LINE_LENGTH);
    msgBuffer[lineIdx][LINE_LENGTH] = '\0';
}

void appendCharToBuffer(char c) {
    if (totalLines == 0) {
        addNewLine();
    }

    if (currentWriteCol >= LINE_LENGTH) {
        addNewLine();
    }

    int lineIdx = (totalLines - 1) % MAX_BUFFER_LINES;
    msgBuffer[lineIdx][currentWriteCol] = c;
    currentWriteCol++;
}

void updateOLEDDisplay(bool rxActive = false) {
    if (!oledFound) return;

    oled.clearDisplay();
    oled.setTextSize(1);
    oled.setTextColor(SSD1306_WHITE);

    // Header bar
    oled.setCursor(0, 0);
    oled.print("NopOS Monitor");
    if (rxActive) {
        oled.setCursor(92, 0);
        oled.print("[RX]");
    }

    oled.drawFastHLine(0, 10, 128, SSD1306_WHITE);

    // Buffer statistics
    oled.setCursor(0, 14);
    oled.print("Buffer: ");
    oled.print(totalLines);
    oled.print(" / ");
    oled.print(MAX_BUFFER_LINES);

    // Scroll Position
    oled.setCursor(0, 26);
    oled.print("Top Line: ");
    oled.print(lastDisplayTopLine >= 0 ? lastDisplayTopLine + 1 : 0);

    // LED States
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

    // Potentiometer Scroll Progress Bar
    int maxTopLine = totalLines - LCD_ROWS;
    int pct = 0;
    if (maxTopLine > 0 && lastDisplayTopLine >= 0) {
        pct = (lastDisplayTopLine * 100) / maxTopLine;
        if (pct > 100) pct = 100;
    }

    oled.drawRect(0, 52, 128, 10, SSD1306_WHITE);
    int fillWidth = map(pct, 0, 100, 0, 124);
    if (fillWidth > 0) {
        oled.fillRect(2, 54, fillWidth, 6, SSD1306_WHITE);
    }

    oled.display();
}

void processCommand(const char* cmd) {
    // Check LED commands: !R1, !R0, !Y1, !Y0, !G1, !G0
    if (strcmp(cmd, "!R1") == 0 || strcmp(cmd, "!RED:ON") == 0) {
        digitalWrite(LED_RED_PIN, HIGH);
        Serial.println("[ESP32] RED LED ON");
    } else if (strcmp(cmd, "!R0") == 0 || strcmp(cmd, "!RED:OFF") == 0) {
        digitalWrite(LED_RED_PIN, LOW);
        Serial.println("[ESP32] RED LED OFF");
    } else if (strcmp(cmd, "!Y1") == 0 || strcmp(cmd, "!YELLOW:ON") == 0) {
        digitalWrite(LED_YELLOW_PIN, HIGH);
        Serial.println("[ESP32] YELLOW LED ON");
    } else if (strcmp(cmd, "!Y0") == 0 || strcmp(cmd, "!YELLOW:OFF") == 0) {
        digitalWrite(LED_YELLOW_PIN, LOW);
        Serial.println("[ESP32] YELLOW LED OFF");
    } else if (strcmp(cmd, "!G1") == 0 || strcmp(cmd, "!GREEN:ON") == 0) {
        digitalWrite(LED_GREEN_PIN, HIGH);
        Serial.println("[ESP32] GREEN LED ON");
    } else if (strcmp(cmd, "!G0") == 0 || strcmp(cmd, "!GREEN:OFF") == 0) {
        digitalWrite(LED_GREEN_PIN, LOW);
        Serial.println("[ESP32] GREEN LED OFF");
    } else if (strcmp(cmd, "!CLEAR") == 0) {
        clearBuffer();
        Serial.println("[ESP32] BUFFER & LCD CLEARED");
    }
    updateOLEDDisplay();
}

int readPotentiometerSmooth(int pin) {
    long sum = 0;
    for (int i = 0; i < 16; i++) {
        sum += analogRead(pin);
    }
    return (int)(sum / 16);
}

void populateTestBuffer() {
    clearBuffer();
    const char* sampleLines[] = {
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
    int count = sizeof(sampleLines) / sizeof(sampleLines[0]);
    for (int i = 0; i < count; i++) {
        addNewLine();
        int lineIdx = (totalLines - 1) % MAX_BUFFER_LINES;
        strncpy(msgBuffer[lineIdx], sampleLines[i], LINE_LENGTH);
        int len = strlen(sampleLines[i]);
        for (int j = len; j < LINE_LENGTH; j++) {
            msgBuffer[lineIdx][j] = ' ';
        }
        msgBuffer[lineIdx][LINE_LENGTH] = '\0';
    }
}

void updateLCDDisplay(bool forceRedraw = false) {
    if (totalLines == 0) {
        updateOLEDDisplay();
        return;
    }

    int maxTopLine = totalLines - LCD_ROWS;
    if (maxTopLine < 0) {
        maxTopLine = 0;
    }

    // Read potentiometer value with 16-sample software averaging
    int adcVal = readPotentiometerSmooth(POT_PIN);

    // Apply hysteresis / deadband to ADC to prevent flickering without capacitors
    if (!forceRedraw && abs(adcVal - lastRawADC) < 45 && lastDisplayTopLine != -1) {
        adcVal = lastRawADC;
    } else {
        lastRawADC = adcVal;
    }

    // Map ADC value to top displayed line (0 to maxTopLine)
    int topLine = map(adcVal, 0, 4095, 0, maxTopLine);
    topLine = constrain(topLine, 0, maxTopLine);

    // Redraw LCD only when display window changes or forced
    if (topLine != lastDisplayTopLine || forceRedraw) {
        lastDisplayTopLine = topLine;

        for (int r = 0; r < LCD_ROWS; r++) {
            int lineToRender = topLine + r;
            lcd.setCursor(0, r);

            if (lineToRender < totalLines) {
                int bufferIndex = lineToRender % MAX_BUFFER_LINES;
                char lineText[LINE_LENGTH + 1];
                memcpy(lineText, msgBuffer[bufferIndex], LINE_LENGTH);
                lineText[LINE_LENGTH] = '\0';
                lcd.print(lineText);
            } else {
                lcd.print("                    "); // 20 spaces
            }
        }
    }

    updateOLEDDisplay();
}

void checkButton() {
    if (digitalRead(BUTTON_PIN) == LOW) {
        unsigned long now = millis();
        if (now - lastButtonPress > 250) { // 250ms debouncing
            lastButtonPress = now;
            clearBuffer();
            updateOLEDDisplay();
            Serial.println("[ESP32] Button Pressed -> LCD & Buffer Cleared!");
        }
    }
}

void setup()
{
    // USB serial debug
    Serial.begin(115200);

    // Configure Pins
    pinMode(POT_PIN, INPUT);
    pinMode(BUTTON_PIN, INPUT_PULLUP);

    pinMode(LED_RED_PIN, OUTPUT);
    pinMode(LED_YELLOW_PIN, OUTPUT);
    pinMode(LED_GREEN_PIN, OUTPUT);

    digitalWrite(LED_RED_PIN, LOW);
    digitalWrite(LED_YELLOW_PIN, LOW);
    digitalWrite(LED_GREEN_PIN, LOW);

    // Initialize Buffer
    clearBuffer();

    // I2C Bus for LCD & OLED (SDA=21, SCL=22)
    Wire.begin(
        LCD_SDA,
        LCD_SCL
    );

    // I2C LCD Initialization
    lcd.init();
    lcd.backlight();
    lcd.clear();

    lcd.setCursor(0, 0);
    lcd.print("NopOS Serial RX");

    lcd.setCursor(0, 1);
    lcd.print("115200 8N1 (20x4)");

    // 0.96" OLED SSD1306 Initialization (Address 0x3C)
    if (oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS)) {
        oledFound = true;
        oled.clearDisplay();
        oled.setTextSize(1);
        oled.setTextColor(SSD1306_WHITE);
        oled.setCursor(0, 10);
        oled.println("NopOS System Dash");
        oled.println("OLED 0x3C Ready!");
        oled.display();
    } else {
        Serial.println("[ESP32] Warning: SSD1306 OLED not found at 0x3C");
    }

    // MAX3232 UART
    RS232.begin(
        BAUD_RATE,
        SERIAL_8N1,
        SERIAL_RX,
        SERIAL_TX
    );

    Serial.println("NopOS serial receiver started");
    Serial.println("115200 8N1 (Scroll: POT34, Clear: BTN23, LEDs: R25, Y26, G27)");

    delay(1000);
    lcd.clear();

    // Populate 16 sample lines on boot so potentiometer scrolling can be tested immediately
    populateTestBuffer();
    updateLCDDisplay(true);
}

void loop()
{
    bool receivedNewData = false;

    // Check button press to clear screen
    checkButton();

    while (RS232.available())
    {
        char c = RS232.read();

        // Echo to USB Serial monitor
        Serial.write(c);

        // Command detection starting with '!'
        if (c == '!') {
            parsingCmd = true;
            cmdIdx = 0;
            cmdBuf[cmdIdx++] = c;
            continue;
        }

        if (parsingCmd) {
            if (c == '\r' || c == '\n' || c == ' ' || cmdIdx >= 14 || c == '\0') {
                cmdBuf[cmdIdx] = '\0';
                processCommand(cmdBuf);
                parsingCmd = false;
                cmdIdx = 0;
            } else {
                cmdBuf[cmdIdx++] = c;
            }
            continue;
        }

        if (c == '\f') {
            clearBuffer();
            receivedNewData = true;
            continue;
        }

        if (c == '\r') {
            continue;
        }

        if (c == '\n') {
            addNewLine();
            receivedNewData = true;
            continue;
        }

        appendCharToBuffer(c);
        receivedNewData = true;
    }

    // Check potentiometer and update displays
    updateLCDDisplay(receivedNewData);

    delay(10);
}