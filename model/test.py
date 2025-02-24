import cv2
import numpy as np
import tensorflow.lite as tflite

def load_tflite_model(model_path):
    interpreter = tflite.Interpreter(model_path=model_path)
    interpreter.allocate_tensors()
    return interpreter

def preprocess_image(image_path, input_shape):
    original_image = cv2.imread(image_path)
    image = cv2.cvtColor(original_image, cv2.COLOR_BGR2RGB)
    image = cv2.resize(image, input_shape)
    image = image.astype(np.float32) / 255.0  
    image = np.expand_dims(image, axis=0)  
    return image, original_image

def run_inference(interpreter, image):
    input_details = interpreter.get_input_details()
    print("Model expects input shape:", input_details[0]['shape'])
    print("Model input details:", input_details)
    output_details = interpreter.get_output_details()
    
    interpreter.set_tensor(input_details[0]['index'], image)
    interpreter.invoke()
    
    outputs = interpreter.get_tensor(output_details[0]['index'])
    return outputs

def process_yolo_output(output_data, img_width, img_height, conf_threshold=0.01):
    predictions = output_data[0]  # Extract tensor from list
    num_detections = predictions.shape[1]  # Number of detections

    boxes = []
    scores = []
    class_ids = []

    for i in range(num_detections):
        row = predictions[:, i]  # Get one detection
        confidence = row[4]  # Confidence score
        if confidence > conf_threshold:
            x_center, y_center, w, h = row[0:4]
            x_min = int((x_center - w / 2) * img_width)
            y_min = int((y_center - h / 2) * img_height)
            x_max = int((x_center + w / 2) * img_width)
            y_max = int((y_center + h / 2) * img_height)
            
            class_id = np.argmax(row[5:])  # Get class ID
            class_conf = row[5 + class_id]  # Get class confidence
            
            boxes.append([y_min, x_min, y_max, x_max])
            scores.append(class_conf)
            class_ids.append(class_id)

    return boxes, scores, class_ids

def draw_detections(image, boxes, scores, class_ids):
    for i in range(len(scores)):
        if scores[i] > 0.01:  
            y_min, x_min, y_max, x_max = boxes[i]
            
            cv2.rectangle(image, (x_min, y_min), (x_max, y_max), (0, 255, 0), 2)
            label = f"Class {int(class_ids[i])}: {scores[i]:.2f}"
            cv2.putText(image, label, (x_min, y_min - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)


    return image

def main():
    model_path = "best.tflite" 
    image_path = "C:\\Users\\Bruce\\Desktop\\New folder (3)\\New folder\\roboflow_dataset\\train\\images\\rgb-2022-10-06-17-17-35_jpg.rf.3986ac3a5a305de0ddb1c32c65e270c9.jpg"
    input_size = (640, 640)  
    
    interpreter = load_tflite_model(model_path)
    image, original_image = preprocess_image(image_path, input_size)
    outputs = run_inference(interpreter, image)
    
    boxes, scores, class_ids = process_yolo_output(outputs, original_image.shape[1], original_image.shape[0])
    result_image = draw_detections(original_image, boxes, scores, class_ids)

    cv2.imshow("Detections", result_image)
    cv2.waitKey(0)
    cv2.destroyAllWindows()

    print("Model outputs processed correctly.")
    
if __name__ == "__main__":
    main()