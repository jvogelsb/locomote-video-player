package com.axis.rtspclient {
  import com.axis.rtspclient.ByteArrayUtils;
  import com.axis.rtspclient.RTP;
  import com.axis.Logger;

  import flash.events.Event;
  import flash.events.EventDispatcher;
  import flash.external.ExternalInterface;
  import flash.utils.ByteArray;

  /* Assembler of PCMU frames */
  public class PCMUFrame extends Event {
    public static const NEW_FRAME:String = "NEW_PCMU_FRAME";

    private var pcmuData:ByteArray = new ByteArray();
    public var timestamp:uint;

    public function PCMUFrame(data:ByteArray, timestamp:uint) {
      super(PCMUFrame.NEW_FRAME);
      this.pcmuData.writeBytes(data, 0)
      this.timestamp = timestamp;
    }

    public function writeStream(output:ByteArray):void {
        output.writeBytes(pcmuData, 0);
    }

    public function getPayload():ByteArray {
      return pcmuData;
    }
  }
}
