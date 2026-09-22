#include <Wire.h>
#include <LiquidCrystal_I2C.h>

#define SERIAL_RX 16
#define SERIAL_TX 17

#define LCD_SDA 21
#define LCD_SCL 22

#define LCD_ADDRESS 0x27
#define LCD_COLS 16
#define LCD_ROWS 2

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
#define LINE_LENGTH 16

LiquidCrystal_I2C lcd(
    LCD_ADDRESS,
    LCD_COLS,
    LCD_ROWS
);

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
}

void updateLCDDisplay(bool forceRedraw = false) {
    if (totalLines == 0) {
        return;
    }

    int maxTopLine = totalLines - LCD_ROWS;
    if (maxTopLine < 0) {
        maxTopLine = 0;
    }

    // Read potentiometer value (0 - 4095)
    int adcVal = analogRead(POT_PIN);

    // Apply hysteresis / deadband to ADC to prevent flickering
    if (!forceRedraw && abs(adcVal - lastRawADC) < 35 && lastDisplayTopLine != -1) {
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
                lcd.print("                ");
            }
        }
    }
}

void checkButton() {
    if (digitalRead(BUTTON_PIN) == LOW) {
        unsigned long now = millis();
        if (now - lastButtonPress > 250) { // 250ms debouncing
            lastButtonPress = now;
            clearBuffer();
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

    // I2C LCD
    Wire.begin(
        LCD_SDA,
        LCD_SCL
    );

    lcd.init();
    lcd.backlight();
    lcd.clear();

    lcd.setCursor(0, 0);
    lcd.print("NopOS Serial");

    lcd.setCursor(0, 1);
    lcd.print("115200 8N1");

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

    // Check potentiometer and update display
    updateLCDDisplay(receivedNewData);

    delay(10);
}