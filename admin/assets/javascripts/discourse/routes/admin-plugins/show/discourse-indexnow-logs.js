import { ajax } from "discourse/lib/ajax";
import DiscourseRoute from "discourse/routes/discourse";

export default class AdminPluginsShowDiscourseIndexNowLogs extends DiscourseRoute {
  model() {
    return ajax("/admin/plugins/discourse-indexnow/logs.json", {
      data: {
        page: 1,
        per_page: 50,
      },
    });
  }

  setupController(controller, model) {
    controller.setProperties({
      model,
      data: model,
    });
  }
}
