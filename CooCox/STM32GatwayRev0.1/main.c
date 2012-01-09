#include "cox_serial.h"
#include "STM32_USART.h"
#include <stm32_pio.h>
#include "stm32f10x.h"
#include "buffer.h"
#include "stdio.h"
#include <CoOS.h>			              /*!< CoOS header file	         */



#include <stm_spi_master.h>
#include "di_msd.h"
#include "watchdog.h"
#include "main.h"
/*----------------------------------------------------------------------*/
	/* FatFs sample project for generic microcontrollers (C)ChaN, 2010      */
	/*----------------------------------------------------------------------*/
//#include "Type.h"
#include "ff.h"
#include "diskio.h"
#include "modem.h"
//#include "http.h"
#include "WSNPacket.h"
// Basestaion ID
uint8_t BaseStnId = 11;


/*---------------------------- Symbol Define -------------------------------*/
#define STACK_SIZE_DEFAULT 200             /*!< Define a Default task size */
#define STACK_SIZE_WATCHDOG 100             /*!< Define a Default task size */
//#define STACK_SIZE_DEFAULT1 400             /*!< Define a Default task size */


/*---------------------------- Variable Define -------------------------------*/
	OS_STK     watchdog_stk[STACK_SIZE_WATCHDOG];	  /*!< Define "taskA" task stack */
	OS_STK     task2_stk[STACK_SIZE_DEFAULT];	  					/*!< Define "taskB" task stack */
	OS_STK     task3_stk[STACK_SIZE_DEFAULT];	  /*!< Define "led" task stack   */
	//OS_STK     task4_stk[STACK_SIZE_DEFAULT];	  /*!< Define "led" task stack   */



/*-----------------------------SD card Variable-----------------------------*/
MSD_Dev sd_var;
MSD_Dev *sd= &sd_var;							// MSD instance

#define MaxRx   100     			// Maximum size of receive buffer
#define MaxTx   100      			// Maximum size of transmit buffer


//cBuffer recvBuffer;
//unsigned char buffer[50];
cBuffer modem_buffer;								// Receive Buffer for modem
unsigned char mBuffer[MaxRx];

uint8_t lclbuff[100];


//Decleration of   serial Ports
COX_SERIAL_PI *myUSART1 = &pi_serial1;
COX_SERIAL_PI *myUSART2 = &pi_serial2;
extern COX_SERIAL_PI *myUSART3;

volatile uint32_t TIME_TICK;									// 10 millseconds counter
void TIME_SET(uint16_t a){ TIME_TICK=a;}                      	// Set 10 millisecond counter to value 'a'


//attach and initilize the leds on stm32 board
COX_PIO_Dev LED0 = COX_PIN(2,8);
COX_PIO_Dev LED1 = COX_PIN(2,9);

//Usart event flag
OS_FlagID flag;

//The mutex is used to get mutual access to the data file  storing the WSN data
OS_MutexID file_mutex;

//Used to get the mutual access to GSM Gprs Modem
OS_MutexID modem_mutex;

//Used to get the mutual access to the Uart2 used for printf
OS_MutexID printf_mutex;


//Queue for Processing the data recieved
#define MAIL_QUEUE_SIZE 16

OS_EventID raw_queue_id;				// Queue for raw packet forwading between task 1 and 2
OS_EventID sd_queue_id;					// Queue for data packet forwarding between task 2 and 3
void *MailQueue[MAIL_QUEUE_SIZE];

extern void Read_Data(unsigned char );
extern char* wsnPacketDecoding(void );
extern FRESULT SDInterface(char *);

uint8_t sdConfig(void)
{
	uint8_t ret;
	COX_PIO_Dev CS = COX_PIN(2,7);			// PORTC7
	COX_SPI_PI *SPI = &pi_spi1;
	COX_PIO_PI *PI = &pi_pio;

	sd-> cs_pin = CS;
	sd-> pio = PI;
	sd-> spi = SPI;

	sd->pio->Init(sd->cs_pin);
	sd->pio->Dir(sd->cs_pin,1);

	sd->spi->Cfg(COX_SPI_CFG_MODE,COX_SPI_MODE0,0);
	sd->spi->Cfg(COX_SPI_CFG_RATE,SPI_BaudRatePrescaler_2,0);
	sd->spi->Cfg(COX_SPI_CFG_BITS,8,0);
	sd->spi->Cfg(COX_SPI_CFG_FSB,COX_MSPI_FSB_MSB,0);
	ret = sd->spi->Init(COX_SPI_MODE0, 2);

	return ret;
}


void USART1_IRQHandler(void)
{
	char ch;
	static char count = 0;
	StatusType result;
	CoEnterISR ();

	//RXNE interrupt occured
	//printf("uart%x\n\r",USART1->SR);
	if(( USART1->SR & 0x20) != (u16)RESET )
	{
		//count ++;
		ch = (USART1->DR & (us16)0x01FF);
		//printf("0x%x  ",ch);
		Read_Data(ch);

	}
	else if(( USART1->SR & 0x08) != (u16)RESET )		// Handling overrun error
	{
		ch = (USART1->DR & (us16)0x01FF);
	}
	CoExitISR ( );
}



/* Used For printf function*/
void pchar(unsigned char c)
{
	USART2->DR =  (c & (us16)0x01FF);
	while (!(USART2->SR & 0x0080));
}


void initSerial(void){
	//bufferInit(&recvBuffer, buffer, 50);

	//Initilize the buffer for Modem
	bufferInit(&modem_buffer, mBuffer, MaxRx);

	// For mote
	myUSART1->Init(9600);
	myUSART1->Cfg( COX_SERIAL_INT_CONF, RXNE_ENABLE,0);


	//Usart for printf-debugging purpose
	myUSART2->Init(115200);

	//Usart for communication with the Modem
	myUSART3->Init(9600);
	myUSART3->Cfg( COX_SERIAL_INT_CONF, RXNE_ENABLE,0);

	//enable the interrupts for usart3
	//NVIC_Configuration_uart(myUSART3);
}


void TmrCallBack(void)
{
	TIME_TICK ++;
}

	/**
	 *******************************************************************************
	 * @brief       "task2" task code
	 * @param[in]   None
	 * @param[out]  None
	 * @retval      None
	 * @par Description
	 * @details    task example to increment a variable
	 *
	 *******************************************************************************
	 */
	void task2 (void* pdata)
	{
		dogDebug *dptr = (dogDebug *) pdata;
		mdmIface modm;
		char buff[16]= "0.0.0.0";
		modm.ip_addr = buff;
		uint8_t res;
		uint16_t br, bw;
		server tcp;

		TIME_SET(0);
		tcp.port ="80";
		tcp.addr = "14.99.56.93";

		sdConfig();

		ntp_time(&modm);
		for(;;)
		{

		/*
				 *  If send.xml file exists that means last uploading was unsuccessful.
				 *  so  first upload the send.xml data of previous failed
				 *  upload trial.
				 * 	If file is not present that means last upload is successful
				 * 	so rename the store.xml to send.xml and try to upload.
				 *  once send.xml is uploaded, append the send.xml to alldata.xml.
				 *  Then delete the send.xml file.
				 */

				WWDG_setDebugState(dptr , ALIVE);
				rc = f_open(&send, "./root/send.xml", FA_READ);
				f_close(&send);
				// If send.xml file does not exists
				if(rc == FR_NO_FILE)
				{
					CoEnterMutexSection(file_mutex);
					rc = f_rename("./root/store.xml", "./root/send.xml");			// Copy store.xml to send.xml
					CoLeaveMutexSection(file_mutex);
					printf("rename=%d\n\r",rc);
					if(rc == 0){
						WWDG_setDebugState(dptr , UPLOADING);
						rc = uploadFile(&modm, "./root/send.xml", &tcp);
					}
					else if (rc == 4){
						// Store.xml is not present
						printf("store.xml not present\n\r");
					}
					else{
						// Some problem with SDcard
						printf("Problem With SD card\n\r");
					}
				}
				else if(rc == FR_OK)
					{
						WWDG_setDebugState(dptr , UPLOADING);
						printf("send.xml present=%d\n\r",rc);
						rc = uploadFile(&modm, "./root/send.xml", &tcp);
					}
					else if(rc == 3){
							printf("SD card not present\n\r");
					}
						else{
							printf("Some problem With SDCard\n\r");
						}

				// If file is uploaded successfully
				if(rc == mdmOK)
				{
					WWDG_setDebugState(dptr , APPENDING);
					// Appending send.xml data to alldata.xml
					printf("Open a send.xml to read\r\n");
					rc = f_open(&send, "./root/send.xml", FA_READ );
					if (rc) die(rc);
					f_sync(&send);

					printf("\r\nWrite to file alldata.xml\r\n");
					rc = f_open(&alldata, "./root/alldata.xml", FA_WRITE|FA_READ);//| FA_CREATE_ALWAYS);
					if (rc) die(rc);
					f_sync(&alldata);

					if( rc == FR_NO_FILE)
					{
						printf("Creating alldata.xml\n\r");
						rc = f_open(&alldata, "./root/alldata.xml", FA_WRITE|FA_READ| FA_CREATE_ALWAYS);
						if (rc) die(rc);
						f_sync(&alldata);
					}

					// If the alldata.xml has already some data present
					if(!(f_size(&alldata) == 0))
					{
						printf("appending data to alldata.xml\n\r");
						// Overwriting the Endtag
						res = f_lseek(&alldata, f_size(&alldata)- strlen(ENDTAG)-1);
						// Read after the head tag
						rc = f_read(&send, lclbuff, strlen(STARTTAG)+2, &br);
						if (rc || !br) die(rc);
						for(res = 0; res < br;res++)
							printf(" %c",lclbuff[res]);

						rc = f_write(&alldata, "\t", 1,&bw);
						if (rc) die(rc);
						f_sync(&alldata);
					}
					//If nothing is present in the file
					else{
						printf("alldata.xml is empty\n\r");
						rc = f_write(&alldata, STARTTAG, strlen(STARTTAG), &bw);
						if (rc) die(rc);
						f_sync(&alldata);
					}

					printf("\n\rcopying content\n\r");
					// Start copying content from send.xml to alldata.xml
					do {

						//printf("File size=%d\n\r",f_size(&send));
						rc = f_read(&send, lclbuff, sizeof(lclbuff), &br);	/* Read a chunk of file */
						printf("rc=%d,br=%d\n\r",rc,br);
						if (rc || !br) break;								/* Error or end of file */
						for(res = 0;res < br ;res++)
							printf(" %c",lclbuff[res]);
						//res = f_lseek(&fil2, f_size(&fil2));

						rc = f_write(&alldata, lclbuff, br, &bw);
						if (rc) break;
						f_sync(&alldata);
					}
					while(f_eof(&send)!= 1);

					rc = f_close(&send);
					if (rc) die(rc);

					rc = f_close(&alldata);
					if (rc) die(rc);

					printf("Deleting send.xml\n\r");
					f_unlink("./root/send.xml");		// Delete the file

				}
			  CoTickDelay (6000);		// For 1 MInute
		 }

	}


	/**
	 *******************************************************************************
	 * @brief       "task3" task code
	 * @param[in]   None
	 * @param[out]  None
	 * @retval      None
	 * @par Description
	 * @details    task example to increment a variable
	 *******************************************************************************
	 */

	void task3 (void* pdata)
	{
		dogDebug *dptr = (dogDebug *) pdata;
		sdConfig();
		  for (;;)
		  {
			  WWDG_setDebugState(dptr , ALIVE);
			  wsnPacketDecoding();

		  }
	}

	/**
	 *******************************************************************************
	 * @brief       "WatchDog" task code
	 * @param[in]   None
	 * @param[out]  None
	 * @retval      None
	 * @par Description
	 * @details    This function use to monitor  "task2" and "task3".
	 *******************************************************************************
	 */

	void taskWatchDog (void* pdata){

	  /* configure and start the watch dog timer */
	  WWDG_dogStart();
	  CoTickDelay (10);
	  for (;;) {

		  /* perform the sanity check  */
		  WWDG_dogCheck();
		  CoTickDelay (10); //delay of 100 milli seconds
	  }
	}


int main(void)
{
	OS_TID task_2,task_3;
	OS_TCID sftmr;

	//Initilize serial configuration
	initSerial();


	//Initilize the LED0 and LED1 structure
	pi_pio.Init(LED0);
	pi_pio.Init(LED1);

	//configure the port as o/p port
	pi_pio.Dir(LED0,1);
	pi_pio.Dir(LED1,1);

	// Initialising RTC clk
	RTC_Timer();

	// Mount Filesystem
	mount(fatfs);

	/*!< Initial CooCox CoOS          */
	CoInitOS();

	// initilize the debug structure for the two task
	WWDG_initDebug(&myDogDebug[0] , 2 , 60000 , 1);//debug structure for task 2, periodicity max 60 seconds
	WWDG_initDebug(&myDogDebug[1] , 3 , 900000 , 1);//debug structure for task 3, periodicity 15 minutes

    /*!< Create three tasks	*/
	CoCreateTask (taskWatchDog,0,0,&watchdog_stk[STACK_SIZE_WATCHDOG-1],STACK_SIZE_WATCHDOG);
    task_2 = CoCreateTask (task2,&myDogDebug[0],2,&task2_stk[200-1],200);
    task_3 = CoCreateTask (task3,&myDogDebug[1],1,&task3_stk[STACK_SIZE_DEFAULT-1],STACK_SIZE_DEFAULT);

    /* Create a mutex: used by the file handling ReadInterface Function */
    file_mutex = CoCreateMutex( );
    // Create a message queue for storing the received characters
    raw_queue_id = CoCreateQueue(MailQueue,MAIL_QUEUE_SIZE,EVENT_SORT_TYPE_FIFO);
    if (raw_queue_id == E_CREATE_FAIL){
    	printf("Cqfail !\n");
    }
    else{
    	printf("QID%d\n", raw_queue_id);
    }

    sftmr = CoCreateTmr(TMR_TYPE_PERIODIC, 1,1, TmrCallBack);
    CoStartTmr (sftmr);
    CoStartOS ();			    /*!< Start multitask	           */


   while (1);                /*!< The code don''t reach here	   */
}



