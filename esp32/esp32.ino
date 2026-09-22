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

LiquidCrystal_I2C lcd(
    LCD_ADDRESS,
    LCD_COLS,
    LCD_ROWS
);

HardwareSerial RS232(2);

void setup()
{
    // USB serial
    Serial.begin(115200);

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
    Serial.println("115200 8N1");
}

void loop()
{
    static int column = 0;
    static int row = 0;

    while (RS232.available())
    {
        char c = RS232.read();

        // Show received data in USB serial monitor
        Serial.write(c);

        if (c == '\f') {
            lcd.clear();
            column = 0;
            row = 0;
            continue;
        }

        // Handle CR/LF
        if (c == '\r')
            continue;

        if (c == '\n')
        {
            column = 0;
            row++;

            if (row >= LCD_ROWS)
                row = 0;

            lcd.setCursor(column, row);

            // Clear the new line
            for (int i = 0; i < LCD_COLS; i++)
                lcd.print(' ');

            lcd.setCursor(0, row);

            continue;
        }

        // Print character
        lcd.setCursor(column, row);
        lcd.print(c);

        column++;

        // Automatically wrap
        if (column >= LCD_COLS)
        {
            column = 0;
            row++;

            if (row >= LCD_ROWS)
                row = 0;

            lcd.setCursor(column, row);
        }
    }
}