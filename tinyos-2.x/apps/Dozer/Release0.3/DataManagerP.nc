/*
 * Name           : DataManagerP.nc
 * Authors        : u-Agri Team 
 * Organization   : C-DAC, Hyderabad
 * Project        : NUCRC, u-Agri
 * Date           : 2007/12/18, 2009/07/31
 *
 *
 * Description    :
 *** The aim of the Module is to sense parameters at specified Periodicities,
 *** packetlize data collected and send it through radio to the BaseStation (sink node).
 *
 *
 *** Contains initializing sensors with default periodicities (Defined at sensors.h), 
 *** setting channels and flags for individual sensor, checking for proper installation 
 *** of MDA300 and creating records for the sensors in the sampler module. 
 *** The module handles readDone events from the sampler, packetilizes the data, 
 *** sends the packet out of radio using the choosen routing module.
 *
 *
 *** The module is capable of handling control data from dissemination component (if choosen),
 *** to take the requested action accordingly. Reactions to the control data can be either a change 
 *** in the sensor periodicities/making a snapshot of the current status of parameters (sensors) 
 *** available to the user. The set of parameters that the module currently supports are temperature,
 *** humidity, rainfall, solar radiation, wind speed & direction. The module avoids overwriting of
 *** packets sent to the radio module by maintaining a queue kind of mechanism at its level and 
 *** checking for the status of the radio before calling 'send'. When no routing module is selected, 
 *** the module takes the overhead of forwarding the data packets to UART, at the sink node. 
 *
 */

module DataManagerP {
  uses {
    interface TDMASchedule;
    command error_t chooseParent();	

   //Sampler Communication
    interface Init as SamplerInit;
    interface SplitControl as SamplerControl;
    interface Sample;
    command error_t PlugPlay(); // support for plug and play
 
    // Interfaces for communication, multihop and serial:
    interface AMPacket;
    interface AMSend as DataSend;
    interface AMSend as SerialSend;
    interface Receive as DataReceive;

    interface Queue<message_t *> as DataQueue;
    interface Pool<message_t> as DataMessagePool;

    // Miscalleny:
    interface Leds;
  }
 
  provides interface Init;
}

implementation {

    #define LWET_THRESHOLD 21                           // Leaf Wetness Threshold 21 for uncoated sensor and 30 for coated/painted one    
    #define LWET_THRESHOLD1 1536                        // For Abhishek's sensors 1536

    // Sensor Types //          
    enum {
      TEMP_TYPE    = 0,
      HUMID_TYPE   = 1,
      BATTERY_TYPE = 2,
      RAIN_TYPE    = 3,
      SMOIST_TYPE  = 4,
      STEMP_TYPE   = 5,
      WSPEED_TYPE  = 6,
      WDIR_TYPE    = 7,
      LWET_TYPE    = 8,
      SOLAR_TYPE   = 9,
      LWET_TYPE1   = 10, 	                        // Furture Purpose      
    };

    task void sendAvailableData();
    error_t addToQueue(SensedData *in);

    static void start_sampling();
    static void fatal_problem();
    static void report_problem();
    static void report_sent();
    static void report_received();

    /* Messages Buffers */
    SensedData packet[MAX_SENSORS];                     // Data Buffers for individual sensors
    message_t msg_send_buffer;                          // Argument to Send/SendMsg (Final Pkt sent out) 
    message_t *msg_ptr;                                 // Pointer to msg_send_buffer
    SensedData *tmpdatapack;                             

    uint16_t parent_id, child_id;			// Parent and Child Node Addresses	
    uint16_t dest;					// Destination Node Address (child_id/parent_id)	
	
    bool ackPending = FALSE;				// Indication of Pending Ack(for the Data Pkt set) from Parent	
    uint8_t missedAcks = 0;				// Acknowledgments missed from the Parent Node consecutively	
        
    uint8_t  ChNo[MAX_SENSORS], Channel[MAX_SENSORS], Flags[MAX_SENSORS]; // ADC/Digital Channel Numbers, Channel Names, Flags to IBADC 
    uint32_t periodicity[MAX_SENSORS];                  // Sensor Periodicities  
    int8_t   record[MAX_SENSORS];                                // Sampler Records 

    uint16_t sensor_bitmap;                             // Bitmap of the Sensors connected to the Mote
    uint16_t bitmap;                                    // Bitmap of the Sensors for which Periodicity is to be changed according to Control Data

    bool sending_packet; 	                        // Flag indicating the status of Radio/UART (Busy/Free)
    bool RadioOn = FALSE;    				// Radio Status, indicated by Scheduler 
    uint16_t packet_ready;                              // Bitmap of the pkts filled in array (packet[10]) 

    /* One Shot Messages Buffers */
    #ifdef DISSMN    
      message_t oneshotpacket;
      message_t one_shot_buffer;
      message_t *oneshotmsg_ptr;
      OneShotData  *tmpsnapshot;
      uint16_t msg_status, pkt_full;                    // Flags used by OneShot to check for Packet Full Condition
    #endif

    uint8_t oneshotflag = 0;                            // Flag indicating the oneshot event
    uint16_t lcount[2]={0,0}, lcountMax[2]={0,0};	// Leaf Wetness Counter, Counter Max Value
    uint16_t lwet[2]={0,0};             		// Leaf Wetness Value    

   /* ----------------------------------------------------
    * Initialize the Sensor Channel Names, Numbers & Flags      
    * ----------------------------------------------------
    */  
    static void init_sensorflags()
    {
    
        // Sensor Channel Names and Numbers
          Channel[TEMP_TYPE]    = TEMPERATURE; ChNo[TEMP_TYPE]    = 0;
          Channel[HUMID_TYPE]   = HUMIDITY;    ChNo[HUMID_TYPE]   = 0;
          Channel[BATTERY_TYPE] = BATTERY;     ChNo[BATTERY_TYPE] = 0;
          Channel[RAIN_TYPE]    = DIGITAL;     ChNo[RAIN_TYPE]    = 0;
          Channel[SMOIST_TYPE]  = ANALOG;      ChNo[SMOIST_TYPE]  = 3;
          Channel[STEMP_TYPE]   = ANALOG;      ChNo[STEMP_TYPE]   = 2;
          Channel[WSPEED_TYPE]  = COUNTER;     ChNo[WSPEED_TYPE]  = 0;
          Channel[WDIR_TYPE]    = ANALOG;      ChNo[WDIR_TYPE]    = 1;
          Channel[LWET_TYPE]    = ANALOG;      ChNo[LWET_TYPE]    = 6;
          Channel[SOLAR_TYPE]   = ANALOG;      ChNo[SOLAR_TYPE]   = 0;
          Channel[LWET_TYPE1]   = ANALOG;      ChNo[LWET_TYPE1]   = 5;


        // Sensor Flags used by IBADC
          Flags[TEMP_TYPE]    = SAMPLER_DEFAULT;
          Flags[HUMID_TYPE]   = SAMPLER_DEFAULT;
          Flags[BATTERY_TYPE] = SAMPLER_DEFAULT;
          Flags[RAIN_TYPE]    = RESET_ZERO_AFTER_READ | RISING_EDGE;
          Flags[SMOIST_TYPE]  = EXITATION_25 | AVERAGE_EIGHT;
          Flags[STEMP_TYPE]   = EXITATION_25;
          Flags[WSPEED_TYPE]  = RESET_ZERO_AFTER_READ;
          Flags[WDIR_TYPE]    = EXITATION_50 | AVERAGE_EIGHT | EXITATION_ALWAYS_ON;
          Flags[LWET_TYPE]    = EXITATION_25 | AVERAGE_EIGHT; 
          Flags[SOLAR_TYPE]   = AVERAGE_SIXTEEN; 
          Flags[LWET_TYPE1]   = EXITATION_33 | AVERAGE_EIGHT; 

    }


   /* -----------------------------------
    * Initialize the Sensor Periodicities       
    * -----------------------------------
    */  
    static void initialize()
    {
          uint16_t i, j;

          // Initialize Sensors with Default Periodicities (Defined in sensors.h)
          periodicity[TEMP_TYPE]    = TEMP_SAMPLING_TIME;
          periodicity[HUMID_TYPE]   = HUMID_SAMPLING_TIME;
          periodicity[BATTERY_TYPE] = BATTERY_SAMPLING_TIME;
          periodicity[RAIN_TYPE]    = RAIN_SAMPLING_TIME;
          periodicity[SMOIST_TYPE]  = SMOIST_SAMPLING_TIME;
          periodicity[STEMP_TYPE]   = STEMP_SAMPLING_TIME;
          periodicity[WSPEED_TYPE]  = WSPEED_SAMPLING_TIME;
          periodicity[WDIR_TYPE]    = WDIR_SAMPLING_TIME;
          periodicity[LWET_TYPE]    = LWET_SAMPLING_TIME;
          periodicity[SOLAR_TYPE]   = SOLAR_SAMPLING_TIME;
          periodicity[LWET_TYPE1]   = LWET_SAMPLING_TIME;

          if (periodicity[LWET_TYPE] != 0) {
            lcountMax[0] = 36000U/periodicity[LWET_TYPE];       // LWET_SAMPLING_TIME when multiplied with lcountMax 
          }                                                     // should give 1 Hour of Sampling Time  

          if (periodicity[LWET_TYPE1] != 0) {
            lcountMax[1] = 36000U/periodicity[LWET_TYPE1];      // LWET_SAMPLING_TIME when multiplied with lcountMax 
          }                                                     // should give 1 Hour of Sampling Time  

          sensor_bitmap = 0;
          for (i=0, j=0x01; i < MAX_SENSORS; i++, j*=2) {
            if (periodicity[i] != 0) {
                sensor_bitmap |= j;
            }
          }

          for (i=0; i < MAX_SENSORS; i++) {
	    packet[i].crop_id = CROP_ID;
	    packet[i].plot_id = PLOT_ID;     
	  }

    }

    // 
    // On bootup, initialize radio and serial communications, and our
    // own state variables.
    //
    command error_t Init.init() {
      // Beginning our initialization phases:
      call SamplerInit.init();                                  // Initialize Sampler
      init_sensorflags();                                       // Initialize Flags, Channels
      initialize();                                             // Initialize Sensor Periodicities

      if (TOS_NODE_ID != BASE_STATION_ADDR) {
        call SamplerControl.start();
      }

      atomic {                                                  // Initialize Flags & Pointers
          msg_ptr = &msg_send_buffer;
          packet_ready = 0;          
          sending_packet = FALSE;
          #ifdef ONESHOT
          oneshotmsg_ptr = &one_shot_buffer;
          msg_status = 0;
          #endif
      }

      #ifdef ONESHOT
      atomic { pkt_full = sensor_bitmap; }
      #endif
      
      return SUCCESS;
    }

    static void start_sampling() {
      uint8_t i=0;

      if (call PlugPlay())                                 // Check for Proper Installation of MDA300
      {
        for (i=0; i < MAX_SENSORS; i++) {                        // Create Records of each Sensor in Sampler for Sampling
          if (periodicity[i] != 0)
            record[i] = call Sample.getSample(ChNo[i],Channel[i],periodicity[i],Flags[i]);
        }
        call Leds.led1On();  	                                  // Green Led on when MDA300 Check says OK
        call Sample.start();                                    //******* Start Sampling Data **********/       

      } else {
        fatal_problem();  	                                  // Red Led on when MDA300 Check says OK
      }
    }

    event void SamplerControl.startDone(error_t error) {
	if (error != SUCCESS) {
          fatal_problem();
	} else {
          start_sampling();	
	}
    }    

    event void SamplerControl.stopDone(error_t error) { }

    event void TDMASchedule.radioWakeup(uint8_t type, uint16_t node_id) {
	switch (type)
        {
	  case TSLOT_DATA_SEND:
	    RadioOn = TRUE;	
	    parent_id = node_id;
	    post sendAvailableData();
 	    break;

	  case TSLOT_DATA_SEND_STOP:
	    RadioOn = FALSE;	
	    if (ackPending) {
	      addToQueue((SensedData*)call DataSend.getPayload(msg_ptr, sizeof(SensedData)));	
	      missedAcks++;
	      if (missedAcks >= MAX_CONSECUTIVE_MISSED_ACKS) {
		call TDMASchedule.clearTableEntry(parent_id, 1);
		call chooseParent();
	        missedAcks = 0;
	      }
	    }
	    break;

          case TSLOT_LISTEN:
            child_id = node_id;
            break;

          case TSLOT_LISTEN_STOP:
            break;

	  default:
	    break;
        }
    }
  /* -------------------------------
   * Tasks and Functions to Queue and
   * Transmit Radio Messages
   * -------------------------------
   */
    error_t addToQueue(SensedData *in) {
      SensedData *out;	

      message_t *newmsg = call DataMessagePool.get();
      if (newmsg == NULL) {
          // drop the message on the floor if we run out of queue space.
        report_problem();
        return FAIL;
      }

      //Data Enqueue.q
      out = (SensedData*)call DataSend.getPayload(newmsg, sizeof(SensedData));
      memcpy(out, in, sizeof(SensedData));

      if (call DataQueue.enqueue(newmsg) != SUCCESS) {
        // drop the message on the floor and hang if we run out of
        // queue space without running out of queue space first (this
        // should not occur).
        call DataMessagePool.put(newmsg);
        fatal_problem();
        return FAIL; 
      }
       
      return SUCCESS; 
    }

    void addLocalDataToQueue()
    {
	uint8_t i, clear_bit;

        for (i=0; i < 11; i++) {
          if (packet_ready & (1 << i)){                          // Find the next packet to send from the array  (packet[10])
            if (addToQueue(&packet[i]) == SUCCESS) {
              clear_bit = ~(1 << i);
              packet_ready = packet_ready & clear_bit;                // Clear the bit for the packet sent
            } else { return; } 
          }
        }

    }

    task void sendTask() {
      if (call DataSend.send(dest, msg_ptr, sizeof(SensedData)) != SUCCESS) {
        report_problem();
      } else {
        sending_packet = TRUE;
      }
    }

    task void uartSendTask() {
      if (call SerialSend.send(0xffff, msg_ptr, sizeof(SensedData)) != SUCCESS) {
        report_problem();
      } else {
        sending_packet = TRUE;
      }
    }


    task void sendAvailableData() { 

	if (call DataQueue.empty()) {
	  addLocalDataToQueue();
	}

	if (call DataQueue.empty() == FALSE) {
	  // non-empty Queue.  Let's start a new one.
	  message_t *queuemsg = call DataQueue.dequeue();
	  if (queuemsg == NULL) {
            fatal_problem();
          }

	  memcpy(msg_ptr, queuemsg, sizeof(message_t));
	  if (call DataMessagePool.put(queuemsg) != SUCCESS) {
	    fatal_problem();
	  }
		
	  if (TOS_NODE_ID != 0) { 
	    dest = parent_id;
	    post sendTask();
	  } else {
            post uartSendTask();
	  }
	  ackPending = TRUE;	
	}

    }	

    event message_t*
    DataReceive.receive(message_t* msg, void *payload, uint8_t len) {
      SensedData *out;	
      SensedData *in;	
      uint16_t src;	

      src = call AMPacket.source(msg); 	
      memcpy(in, (SensedData*)payload, sizeof(SensedData));

      switch (in->type) {
	case DATA_MSG:
	  if(src != child_id) { return msg;}

	  if (addToQueue(in) == SUCCESS) {
	    out = (SensedData*)call DataSend.getPayload(msg_ptr, sizeof(SensedData));	
            memcpy(out, &in, sizeof(SensedData));
	    out->type = DATA_ACK;
	    out->more = DATA_QUEUE_SIZE - call DataQueue.size();
	    dest = child_id;
            post sendTask(); 
	  }
	  break;

        case DATA_ACK:
	  if(src != parent_id) { return msg;}
	  missedAcks = 0;
	  ackPending = FALSE;
	  if (!(in->more) | !RadioOn) { return msg; }
	  post sendAvailableData();
          break;

	default:  	
          break;
      }
      return msg;
    }
		

   /* ----------------------------------------
    * Handle completion of sent RF Data packet
    * ----------------------------------------
    */
    event void DataSend.sendDone(message_t* msg, error_t error) {
      sending_packet = FALSE;                                   // Set Radio Flag to free 
    }

   /* ----------------------------------------
    * Handle completion of sent UART Data packet
    * ----------------------------------------
    */
    event void SerialSend.sendDone(message_t* msg, error_t error) {
      sending_packet = FALSE;                                   // Set Radio Flag to free 
    }

   /* -----------------------------------
    * Handle readDone events for Sensors 
    * -----------------------------------
    */
    event error_t
    Sample.readDone(uint8_t channel,uint8_t channelType,uint16_t data)
    {
        switch (channelType) {
         case ANALOG:                                            // ANALOG case
             switch (channel) {
             case 0:                                             // ADC Channel '0'
                 tmpdatapack= (SensedData *)&packet[9];
                 tmpdatapack->sensor_id = SOLAR_TYPE;            // Fill the Sensor type
                 tmpdatapack->value = data;                      // Fill the Data value
                 atomic {
                   packet_ready = packet_ready | (1 << 9);       // Set bit in packet_ready bitmap 
                 }
                 break;

             case 7:                                             // ADC Channel '7' 
                 tmpdatapack=(SensedData *)&packet[9];
                 tmpdatapack->sensor_id = SOLAR_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                   packet_ready = packet_ready | (1 << 9);
                 }
                 break;

             case 5:                                             // ADC Channel '5'
                 lcount[1]++;                                    // Increment Leaf Wetness Counter till lcountMax 
                 if(data > LWET_THRESHOLD1)                      // Check if ADC value crosses LWet Threshold('1536' C-DAC) 
                      lwet[1] = lwet[1] + 1; 

                 if(lcount != lcountMax) 
                    return SUCCESS;              
                 
                 //Fill the packet when LWet counter reaches <30> (Every Hour)
                 tmpdatapack=(SensedData *)&packet[10];
                 tmpdatapack->sensor_id = LWET_TYPE1;
                 tmpdatapack->value = lwet[1];  
                 atomic {
                  packet_ready = packet_ready | (1 << 10);
                  lcount[1] = 0;                                 // Set LWet Counter, Values to zero  
                  lwet[1] = 0;
                 }
                 break;

             case 6:                                             // ADC Channel '6'
                 lcount[0]++;                                    // Increment Leaf Wetness Counter till lcountMax 
                 if(data > LWET_THRESHOLD)                       // Check if ADC value crosses LWet Threshold('21' Campbell) 
                      lwet[0] = lwet[0] + 1; 

                 if(lcount != lcountMax) 
                    return SUCCESS;              
                 
                 //Fill the packet when LWet counter reaches <30> (Every Hour)
                 tmpdatapack=(SensedData *)&packet[8];
                 tmpdatapack->sensor_id = LWET_TYPE;
                 tmpdatapack->value = lwet[0];  
                 atomic {
                  packet_ready = packet_ready | (1 << 8);
                  lcount[0] = 0;                                 // Set LWet Counter, Values to zero  
                  lwet[0] = 0;
                 }
                 break;

             case 1:                                             // ADC Channel '1'
                 tmpdatapack=(SensedData *)&packet[7];
                 tmpdatapack->sensor_id = WDIR_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                  packet_ready = packet_ready | (1 << 7);
                 }
                 break;

             case 2:                                             // ADC Channel '2'
                 tmpdatapack=(SensedData *)&packet[5];
                 tmpdatapack->sensor_id = STEMP_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                  packet_ready = packet_ready | (1 << 5);
                 }
                 break;

             case 3:                                             // ADC Channel '3'
                 tmpdatapack=(SensedData *)&packet[4];
                 tmpdatapack->sensor_id = SMOIST_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                  packet_ready = packet_ready | (1 << 4);
                 }
                 break;

             default:
                 break;
             }                                                   // Closing case ANALOG (channel) 
             break;
         /* --------------------------------------------------------------------- */

         case DIGITAL:                                           // DIGITAL case
             switch (channel) {
             case 0:
                 tmpdatapack=(SensedData *)&packet[3];
                 tmpdatapack->sensor_id = RAIN_TYPE;
                 tmpdatapack->value = data;                      // Fill in the data value       
                 atomic {
                  packet_ready = packet_ready | (1 << 3);        // Set bit in packet_ready bitmap               
                 }
                 break;

             default:
                 break;
             }  
             break;
         /* --------------------------------------------------------------------- */

         case BATTERY:                                           // BATTERY
                 if(oneshotflag)                                 // If the event is from "OneShot get_data" ignore
                   return SUCCESS;

                 tmpdatapack=(SensedData *)&packet[2];
                 tmpdatapack->sensor_id = BATTERY_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                  packet_ready = packet_ready | (1 << 2);
                 }
                 break;

         case HUMIDITY:                                          // HUMDITY
                 if(oneshotflag)
                   return SUCCESS;

                 tmpdatapack=(SensedData *)&packet[1];
                 tmpdatapack->sensor_id = HUMID_TYPE;
                 tmpdatapack->value = data;
                 atomic {
                  packet_ready = packet_ready | (1 << 1);
                 }
                 break;

         case TEMPERATURE:                                       // TEMPERATURE  
                 if(oneshotflag)
                   return SUCCESS;
                 tmpdatapack=(SensedData *)&packet[0];
                 tmpdatapack->sensor_id = TEMP_TYPE;
                 tmpdatapack->value = data ;
                 atomic {
                  packet_ready = packet_ready | (1 << 0);
                 }
                 break;

         case COUNTER:                                           // COUNTER
                 tmpdatapack=(SensedData *)&packet[6];
                 tmpdatapack->sensor_id = WSPEED_TYPE;
                 tmpdatapack->value = data ;
                 atomic {
                  packet_ready = packet_ready | (1 << 6);
                 }
                 break;

         default:
             break;

         }  // switch (channelType) 
         /* --------------------------------------------------------------------- */


           if (sending_packet) {                                  // Check if Radio is Busy, if so return
    	       report_received();
               return SUCCESS;
	   }

           addLocalDataToQueue();                                // Post the task to send the next data packet

      return SUCCESS;
    }


    // Use LEDs to report various status issues.
    static void fatal_problem() { 
      call Leds.led0On(); 
    /*  call Leds.led1On();
      call Leds.led2On();*/
    }

    static void report_problem() { call Leds.led0Toggle(); }
    static void report_sent() { call Leds.led1Toggle(); }
    static void report_received() { call Leds.led2Toggle(); }
}
